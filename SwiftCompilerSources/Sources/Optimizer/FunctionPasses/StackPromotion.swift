//===--- StackPromotion.swift - Stack promotion optimization --------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import SIL

/// Promotes heap allocated objects to the stack.
///
/// It handles `alloc_ref` and `alloc_ref_dynamic` instructions of native swift
/// classes: if promoted, the `[stack]` attribute is set in the allocation
/// instruction and a `dealloc_stack_ref` is inserted at the end of the object's
/// lifetime.

/// The main criteria for stack promotion is that the allocated object must not
/// escape its function.
///
/// Example:
///   %k = alloc_ref $Klass
///   // .. some uses of %k
///   destroy_value %k  // The end of %k's lifetime
///
/// is transformed to:
///
///   %k = alloc_ref [stack] $Klass
///   // .. some uses of %k
///   destroy_value %k
///   dealloc_stack_ref %k
///
/// The destroy/release of the promoted object remains in the SIL, but is effectively
/// a no-op, because a stack promoted object is initialized with an "immortal"
/// reference count.
/// Later optimizations can clean that up.
let stackPromotion = FunctionPass(name: "stack-promotion", {
  (function: Function, context: PassContext) in

  var escapeInfo = EscapeInfo(calleeAnalysis: context.calleeAnalysis)
  let deadEndBlocks = context.deadEndBlocks

  var changed = false
  for block in function.blocks {
    for inst in block.instructions {
      if let ar = inst as? AllocRefInstBase {
        if deadEndBlocks.isDeadEnd(block) {
          // Don't stack promote any allocation inside a code region which ends up
          // in a no-return block. Such allocations may missing their final release.
          // We would insert the deallocation too early, which may result in a
          // use-after-free problem.
          continue
        }
        if !context.continueWithNextSubpassRun(for: ar) {
          break
        }

        if tryPromoteAlloc(ar, &escapeInfo, deadEndBlocks, context) {
          changed = true
        }
      }
    }
  }
  if changed {
    // Make sure that all stack allocating instructions are nested correctly.
    context.fixStackNesting(function: function)
  }
})

private
func tryPromoteAlloc(_ allocRef: AllocRefInstBase,
                     _ escapeInfo: inout EscapeInfo,
                     _ deadEndBlocks: DeadEndBlocksAnalysis,
                     _ context: PassContext) -> Bool {
  if allocRef.isObjC || allocRef.canAllocOnStack {
    return false
  }

  // The most important check: does the object escape the current function?
  if escapeInfo.isEscaping(object:allocRef) {
    return false
  }

  // Try to find the top most dominator block which dominates all use points.
  // * This block can be located "earlier" than the actual allocation block, in case the
  //   promoted object is stored into an "outer" object, e.g.
  //
  //   bb0:           // outerDominatingBlock                 _
  //     %o = alloc_ref $Outer                                 |
  //     ...                                                   |
  //   bb1:           // allocation block      _               |
  //     %k = alloc_ref $Klass                  |              | "outer"
  //     %f = ref_element_addr %o, #Outer.f     | "inner"      | liferange
  //     store %k to %f                         | liferange    |
  //     ...                                    |              |
  //     destroy_value %o                      _|             _|
  //
  // * Finding the `outerDominatingBlock` is not guaranteed to work.
  //   In this example, the top most dominator block is `bb0`, but `bb0` has no
  //   use points in the outer liferange. We'll get `bb3` as outerDominatingBlock.
  //   This is no problem because 1. it's an unusual case and 2. the `outerBlockRange`
  //   is invalid in this case and we'll bail later.
  //
  //   bb0:                    // real top most dominating block
  //     cond_br %c, bb1, bb2
  //   bb1:
  //     %o1 = alloc_ref $Outer
  //     br bb3(%o1)
  //   bb2:
  //     %o2 = alloc_ref $Outer
  //     br bb3(%o1)
  //   bb3(%o):                // resulting outerDominatingBlock: wrong!
  //     %k = alloc_ref $Klass
  //     %f = ref_element_addr %o, #Outer.f
  //     store %k to %f
  //     destroy_value %o
  //
  let domTree = context.dominatorTree
  let outerDominatingBlock = escapeInfo.getDominatingBlockOfAllUsePoints(allocRef, domTree: domTree)

  // The "inner" liferange contains all use points which are dominated by the allocation block
  var innerRange = InstructionRange(begin: allocRef, context)
  defer { innerRange.deinitialize() }

  // The "outer" liferange contains all use points.
  var outerBlockRange = BasicBlockRange(begin: outerDominatingBlock, context)
  defer { outerBlockRange.deinitialize() }
  
  escapeInfo.computeInnerAndOuterLiferanges(&innerRange, &outerBlockRange, domTree: domTree)

  precondition(innerRange.blockRange.isValid, "inner range should be valid because we did a dominance check")

  if !outerBlockRange.isValid {
    // This happens if we fail to find a correct outerDominatingBlock.
    return false
  }

  // Check if there is a control flow edge from the inner to the outer liferange, which
  // would mean that the promoted object can escape to the outer liferange.
  // This can e.g. be the case if the inner liferange does not post dominate the outer range:
  //                                                              _
  //     %o = alloc_ref $Outer                                     |
  //     cond_br %c, bb1, bb2                                      |
  //   bb1:                                            _           |
  //     %k = alloc_ref $Klass                          |          | outer
  //     %f = ref_element_addr %o, #Outer.f             | inner    | range
  //     store %k to %f                                 | range    |
  //     br bb2       // branch from inner to outer    _|          |
  //   bb2:                                                        |
  //     destroy_value %o                                         _|
  //
  // Or if there is a loop with a back-edge from the inner to the outer range:
  //                                                              _
  //     %o = alloc_ref $Outer                                     |
  //     br bb1                                                    |
  //   bb1:                                            _           |
  //     %k = alloc_ref $Klass                          |          | outer
  //     %f = ref_element_addr %o, #Outer.f             | inner    | range
  //     store %k to %f                                 | range    |
  //     cond_br %c, bb1, bb2   // inner -> outer      _|          |
  //   bb2:                                                        |
  //     destroy_value %o                                         _|
  //
  if innerRange.blockRange.isControlFlowEdge(to: outerBlockRange) {
    return false
  }

  // There shouldn't be any critical exit edges from the liferange, because that would mean
  // that the promoted allocation is leaking.
  // Just to be on the safe side, do a check and bail if we find critical exit edges: we
  // cannot insert instructions on critical edges.
  if innerRange.blockRange.containsCriticalExitEdges(deadEndBlocks: deadEndBlocks) {
    return false
  }

  // Do the transformation!
  // Insert `dealloc_stack_ref` instructions at the exit- and end-points of the inner liferange.
  for exitInst in innerRange.exits {
    if !deadEndBlocks.isDeadEnd(exitInst.block) {
      let builder = Builder(at: exitInst, context)
      _ = builder.createDeallocStackRef(allocRef)
    }
  }

  for endInst in innerRange.ends {
    Builder.insert(after: endInst, location: allocRef.location, context) {
      (builder) in _ = builder.createDeallocStackRef(allocRef)
    }
  }

  allocRef.setIsStackAllocatable(context)
  return true
}

//===----------------------------------------------------------------------===//
//                              utility functions
//===----------------------------------------------------------------------===//

private extension EscapeInfo {
  mutating func getDominatingBlockOfAllUsePoints(_ value: SingleValueInstruction,
                                                 domTree: DominatorTree) -> BasicBlock {
    // The starting point
    var dominatingBlock = value.block

    _ = isEscaping(object: value, visitUse: { op, _, _ in
        let defBlock = op.value.definingBlock
        if defBlock.dominates(dominatingBlock, domTree) {
          dominatingBlock = defBlock
        }
        return .continueWalking
      })
    return dominatingBlock
  }

  /// All uses which are dominated by the `innerInstRange`s begin-block are included
  /// in both, the `innerInstRange` and the `outerBlockRange`.
  /// All _not_ dominated uses are only included in the `outerBlockRange`.
  mutating
  func computeInnerAndOuterLiferanges(_ innerInstRange: inout InstructionRange,
                                      _ outerBlockRange: inout BasicBlockRange,
                                      domTree: DominatorTree) {
    _ = isEscaping(object: innerInstRange.begin as! SingleValueInstruction, visitUse: { op, _, _ in
        let user = op.instruction
        if innerInstRange.blockRange.begin.dominates(user.block, domTree) {
          innerInstRange.insert(user)
        }
        outerBlockRange.insert(user.block)

        let val = op.value
        let defBlock = val.definingBlock

        // Also insert the operand's definition. Otherwise we would miss allocation
        // instructions (for which the `visitUse` closure is not called).
        outerBlockRange.insert(defBlock)
        
        // We need to explicitly add predecessor blocks of phi-arguments becaues they
        // are not necesesarily visited by `EscapeInfo.walkDown`.
        // This is important for the special case where there is a back-edge from the
        // inner range to the inner rage's begin-block:
        //
        //   bb0:                      // <- need to be in the outer range
        //     br bb1(%some_init_val)
        //   bb1(%arg):
        //     %k = alloc_ref $Klass   // innerInstRange.begin
        //     cond_br bb2, bb1(%k)    // back-edge to bb1 == innerInstRange.blockRange.begin
        //
        if val is BlockArgument {
          outerBlockRange.insert(contentsOf: defBlock.predecessors)
        }
        return .continueWalking
      })
  }
}

private extension BasicBlockRange {
  /// Returns true if there is a direct edge connecting this range with the `otherRange`.
  func isControlFlowEdge(to otherRange: BasicBlockRange) -> Bool {
    func isOnlyInOtherRange(_ block: BasicBlock) -> Bool {
      return !inclusiveRangeContains(block) &&
             otherRange.inclusiveRangeContains(block) && block != otherRange.begin
    }

    for lifeBlock in inclusiveRange {
      precondition(otherRange.inclusiveRangeContains(lifeBlock), "range must be a subset of other range")
      for succ in lifeBlock.successors {
        if isOnlyInOtherRange(succ) {
          return true
        }
        // The entry of the begin-block is conceptually not part of the range. We can check if
        // it's part of the `otherRange` by checking the begin-block's predecessors.
        if succ == begin && begin.predecessors.contains(where: { isOnlyInOtherRange($0) }) {
          return true
        }
      }
    }
    return false
  }

  func containsCriticalExitEdges(deadEndBlocks: DeadEndBlocksAnalysis) -> Bool {
    exits.contains { !deadEndBlocks.isDeadEnd($0) && !$0.hasSinglePredecessor }
  }
}
