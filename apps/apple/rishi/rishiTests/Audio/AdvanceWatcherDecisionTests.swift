//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//
//import Foundation
//import Testing
//import RishiAudio
//@testable import rishi
//
//@Suite("AdvanceWatcherDecision")
//@MainActor
//struct AdvanceWatcherDecisionTests {
//
//    
//    
//    
//    @Test("advances on loading->stopped even when .playing was never observed")
//    func advancesWhenPlayingNeverObserved() {
//        var decision = AdvanceWatcherDecision()
//        #expect(decision.observe(.loading) == .wait)
//        #expect(decision.observe(.stopped) == .advance)
//    }
//
//    
//    @Test("advances on the normal loading->playing->stopped sequence")
//    func advancesOnNormalSequence() {
//        var decision = AdvanceWatcherDecision()
//        #expect(decision.observe(.loading) == .wait)
//        #expect(decision.observe(.playing) == .wait)
//        #expect(decision.observe(.playing) == .wait)
//        #expect(decision.observe(.stopped) == .advance)
//    }
//
//    
//    
//    @Test("does not advance off a residual .stopped seen before start")
//    func ignoresResidualStoppedBeforeStart() {
//        var decision = AdvanceWatcherDecision()
//        #expect(decision.observe(.stopped) == .wait)
//        #expect(decision.observe(.idle) == .wait)
//        #expect(decision.observe(.loading) == .wait)
//        #expect(decision.observe(.stopped) == .advance)
//    }
//
//    
//    @Test("advances when only .playing was observed before .stopped")
//    func advancesWhenOnlyPlayingObserved() {
//        var decision = AdvanceWatcherDecision()
//        #expect(decision.observe(.playing) == .wait)
//        #expect(decision.observe(.stopped) == .advance)
//    }
//
//    
//    @Test("bails on .error")
//    func bailsOnError() {
//        var decision = AdvanceWatcherDecision()
//        #expect(decision.observe(.loading) == .wait)
//        #expect(decision.observe(.error) == .bail)
//    }
//
//    
//
//    
//    
//    
//    
//    
//    
//    @Test("advances on .stopped for the target passage id even if start was never observed")
//    func advancesOnStoppedForTargetPassageEvenWithoutObservedStart() {
//        var decision = AdvanceWatcherDecision(targetPassageId: "1")
//        #expect(decision.observe(status: .stopped, passageId: "1") == .advance)
//    }
//
//    
//    
//    
//    
//    @Test("does not advance off a residual .stopped carrying a different passage id")
//    func ignoresResidualStoppedForDifferentPassage() {
//        var decision = AdvanceWatcherDecision(targetPassageId: "1")
//        #expect(decision.observe(status: .stopped, passageId: "0") == .wait)
//        #expect(decision.observe(status: .loading, passageId: "1") == .wait)
//        #expect(decision.observe(status: .stopped, passageId: "1") == .advance)
//    }
//
//    
//    
//    @Test("advances on normal sequence when passage id matches throughout")
//    func advancesOnNormalSequenceWithMatchingId() {
//        var decision = AdvanceWatcherDecision(targetPassageId: "2")
//        #expect(decision.observe(status: .loading, passageId: "2") == .wait)
//        #expect(decision.observe(status: .playing, passageId: "2") == .wait)
//        #expect(decision.observe(status: .stopped, passageId: "2") == .advance)
//    }
//
//    
//    
//    
//    @Test("advances on .stopped with nil id when target start was observed")
//    func advancesOnStoppedNilIdAfterObservedStart() {
//        var decision = AdvanceWatcherDecision(targetPassageId: "3")
//        #expect(decision.observe(status: .playing, passageId: "3") == .wait)
//        #expect(decision.observe(status: .stopped, passageId: nil) == .advance)
//    }
//
//    
//    @Test("bails on .error on the passage-aware path")
//    func bailsOnErrorPassageAware() {
//        var decision = AdvanceWatcherDecision(targetPassageId: "1")
//        #expect(decision.observe(status: .loading, passageId: "1") == .wait)
//        #expect(decision.observe(status: .error, passageId: "1") == .bail)
//    }
//}
