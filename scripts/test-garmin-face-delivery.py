#!/usr/bin/env python3
"""Compile the production face coordinator; exercise transport failures and races.

Virtual timers/SDK completions are injected. This does not claim live BLE proof.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
manager = (root/'Trio/Sources/Services/WatchManager/GarminManager.swift').read_text()
source = manager[manager.index('// MARK: - Latest-only face delivery'):]
checks = r'''
import Foundation
func payload(_ date: UInt64, _ iob: Int = 1) -> Data {
    try! JSONSerialization.data(withJSONObject: [["glucoseDate":date,"sgv":123,"iob":iob]], options: [.sortedKeys])
}
final class Harness {
    struct Request {
        let key: String
        let data: Data
        let current: () -> Bool
        let complete: (Bool) -> Void
    }
    var requests: [Request] = []
    var timers: [(Double, () -> Void)] = []
    var now = 0.0
    lazy var engine = GarminFaceDelivery(send: { [unowned self] key, data, current, complete in
        self.requests.append(Request(key:key, data:data, current:current, complete:complete))
    }, schedule: { [unowned self] delay, action in self.timers.append((self.now+delay, action)) })
    func advance(_ seconds: Double) {
        let target = now + seconds
        while let index = timers.indices.filter({timers[$0].0 <= target}).min(by: {timers[$0].0 < timers[$1].0}) {
            let (time, action) = timers.remove(at: index)
            now = time; action()
        }
        now = target
    }
}
var count=0
func test(_ name: String, _ body: () -> Void) { body(); count += 1; print("PASS: \(name)") }
let a=payload(100), b=payload(200), c=payload(300)
test("failed face does not suppress another, identical payload retries") {
    let h=Harness(); h.engine.replaceDestinations(["d:A","d:B"]); h.engine.offer(a)
    precondition(h.requests.count==1)
    h.requests[0].complete(false)
    precondition(h.requests.count==2 && h.requests[1].key=="d:B")
    h.requests[1].complete(true); h.engine.offer(a); h.advance(2)
    precondition(h.requests.count==3 && h.requests[2].key=="d:A")
    h.requests[2].complete(true); h.engine.offer(a); h.advance(60)
    precondition(h.requests.count==3)
}
test("newest payload replaces delayed retry") {
    let h=Harness(); h.engine.replaceDestinations(["A"]); h.engine.offer(a)
    h.requests[0].complete(false); h.engine.offer(b)
    precondition(h.requests.count==2 && h.requests[1].data==b)
    h.requests[1].complete(true); h.advance(60); precondition(h.requests.count==2)
}
test("coalesce in-flight history, do not send superseded status result") {
    let h=Harness(); h.engine.replaceDestinations(["A"]); h.engine.offer(a)
    h.engine.offer(b); h.engine.offer(c); precondition(!h.requests[0].current())
    h.requests[0].complete(false)
    precondition(h.requests.count==2 && h.requests[1].data==c && h.requests[1].current())
}
test("old success acknowledges only its original payload") {
    let h=Harness(); h.engine.replaceDestinations(["A"]); h.engine.offer(a); h.engine.offer(b)
    h.requests[0].complete(true); precondition(h.requests.count==2 && h.requests[1].data==b)
    h.requests[0].complete(true); precondition(h.requests[1].current())
}
test("missing SDK callback times out without blocking other faces") {
    let h=Harness(); h.engine.replaceDestinations(["A","B"]); h.engine.offer(a); h.advance(25)
    precondition(h.requests.count==2 && h.requests[1].key=="B")
    h.requests[0].complete(true); precondition(h.requests[1].current())
    h.requests[1].complete(true); h.advance(2); precondition(h.requests.count==3)
}
test("disabled/removed destinations reject outstanding callbacks and retries") {
    let h=Harness(); h.engine.replaceDestinations(["A"]); h.engine.offer(a)
    h.engine.replaceDestinations([]); precondition(!h.requests[0].current())
    h.requests[0].complete(false); h.advance(90); precondition(h.requests.count==1)
    h.engine.replaceDestinations(["B"]); precondition(h.requests.count==2 && h.requests[1].key=="B")
}
test("re-registration invalidates earlier registration acknowledgements") {
    let h=Harness(); h.engine.replaceDestinations(["A"]); h.engine.offer(a)
    h.engine.replaceDestinations(["A"]); precondition(h.requests.count==2)
    h.requests[0].complete(true); precondition(h.requests[1].current())
}
test("reconnect retries identical data for only the affected watch") {
    let h=Harness(); h.engine.replaceDestinations(["one:A","two:A"]); h.engine.offer(a)
    h.requests[0].complete(true); h.requests[1].complete(true)
    h.engine.reconnect(prefix:"one:")
    precondition(h.requests.count==3 && h.requests[2].key=="one:A")
    h.requests[2].complete(true); h.engine.offer(a); precondition(h.requests.count==3)
}
test("older preparation cannot replace newer pending data; same-date updates allowed") {
    let h=Harness(); h.engine.replaceDestinations(["A"]); h.engine.offer(b); h.engine.offer(a)
    precondition(h.requests[0].current()); h.requests[0].complete(true)
    h.engine.offer(payload(200,2)); precondition(h.requests.count==2)
    h.engine.offer(payload(UInt64.max)); h.engine.offer(Data("[]".utf8)); h.engine.offer(Data("{}".utf8)); h.engine.offer(Data("bad".utf8))
    precondition(h.requests[1].current())
}
test("bounded retries, later identical broadcast gets another chance") {
    let h=Harness(); h.engine.replaceDestinations(["A"]); h.engine.offer(a)
    h.requests[0].complete(false); h.advance(2)
    h.requests[1].complete(false); h.advance(8)
    h.requests[2].complete(false); h.advance(20)
    h.requests[3].complete(false); h.advance(120); precondition(h.requests.count==4)
    h.engine.offer(a); precondition(h.requests.count==5)
}
test("round-robin scheduling avoids starving other faces") {
    let h=Harness(); h.engine.replaceDestinations(["A","B","C"]); h.engine.offer(a); h.engine.offer(b)
    h.requests[0].complete(true); precondition(h.requests[1].key=="B" && h.requests[1].data==b)
    h.requests[1].complete(true); precondition(h.requests[2].key=="C")
    h.requests[2].complete(true); precondition(h.requests[3].key=="A" && h.requests[3].data==b)
}
test("concurrent offers keep maximum reading timestamp") {
    let h=Harness(); h.engine.replaceDestinations(["A"]); h.engine.offer(a)
    DispatchQueue.concurrentPerform(iterations:100) { h.engine.offer(payload(UInt64(1000+$0))) }
    h.requests[0].complete(false)
    precondition(h.requests.count==2 && h.requests[1].data==payload(1099))
}
test("all sixteen retained destinations receive independent acknowledgements") {
    let names=["aviator","navitimer","quadrant","chronometer","iwcPerpetual","grandmaster",
               "yachtMaster","daytona","skyDweller","yachtMasterII","fieldGMT","luminor",
               "premier","lange","apSport","bigBang"]
    let h=Harness(); h.engine.replaceDestinations(names); h.engine.offer(a)
    for i in 0..<16 { precondition(h.requests[i].key==names[i]); h.requests[i].complete(true) }
    precondition(h.requests.count==16); h.engine.offer(a); precondition(h.requests.count==16)
    h.engine.offer(b)
    for i in 16..<32 { precondition(h.requests[i].key==names[i-16] && h.requests[i].data==b); h.requests[i].complete(true) }
    precondition(h.requests.count==32)
}
print("All \(count) production coordinator scenarios passed")
'''
with tempfile.TemporaryDirectory(prefix='trio-face-delivery-') as directory:
    path=Path(directory)/'main.swift'
    path.write_text('import Foundation\n'+source+'\n'+checks)
    binary=Path(directory)/'tests'
    subprocess.run(['xcrun','swiftc',str(path),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
