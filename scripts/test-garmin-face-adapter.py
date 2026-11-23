#!/usr/bin/env python3
"""Compile the real SDK adapter with fake SDK types; no Bluetooth is exercised."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'Trio/Sources/Services/WatchManager/GarminManager.swift').read_text()
a=s.index('    private func sendFaceState(');b=s.index('    // MARK: - GarminManager Conformance',a)
adapter=s[a:b].replace('private func sendFaceState','func sendFaceState',1)
checks=r'''
import Foundation
enum LogKind { case watchManager }
func debug(_ kind: LogKind, _ text: String) {}
class IQDevice { let uuid=UUID() }
class IQApp { let device:IQDevice?; init(_ d:IQDevice?) { device=d } }
struct Status { let isInstalled:Bool }
enum Result { case success, failure }
class SDK {
 var status:((Status?)->Void)?
 var sends=0
 var result:Result = .success
 func getAppStatus(_ app:IQApp, completion:@escaping(Status?)->Void) { status=completion }
 func sendMessage(_ json:Any, to app:IQApp, progress:(Int,Int)->Void, completion:(Result)->Void) { sends+=1; completion(result) }
}
class Manager {
 var isWatchfaceDataEnabled=true
 var faceApps:[String:IQApp]=[:]
 var readyDevices=Set<UUID>()
 var connectIQ:SDK?=SDK()
 func debugGarmin(_ text:String) {}
ADAPTER
}
func drain() { RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
let data=Data("[{\"glucoseDate\":123,\"sgv\":100}]".utf8)
for scenario in 0..<8 {
 let m=Manager(),device=IQDevice();m.faceApps["face"]=IQApp(device);m.readyDevices.insert(device.uuid)
 let sdk=m.connectIQ!;var current=true;var result:Bool?
 if scenario==0 { m.readyDevices=[] }
 if scenario==1 { m.connectIQ=nil }
 m.sendFaceState(key:"face",data:data,current:{current},completion:{result=$0})
 if scenario==2 { current=false }
 if scenario==3 { m.isWatchfaceDataEnabled=false }
 if scenario==4 { m.faceApps=[:] }
 if scenario==5 { sdk.result = .failure }
 sdk.status?(scenario==6 ? nil : Status(isInstalled:true));drain()
 precondition(result == (scenario==7),"Unexpected result for scenario \(scenario)")
 precondition(sdk.sends == ((scenario==5 || scenario==7) ? 1 : 0),"Stale/disabled send for \(scenario)")
}
print("PASS: 8 production adapter eligibility/completion scenarios")
'''.replace('ADAPTER',adapter)
with tempfile.TemporaryDirectory(prefix='trio-face-adapter-') as d:
 p=Path(d)/'main.swift';p.write_text(checks);binary=Path(d)/'test'
 subprocess.run(['xcrun','swiftc',str(p),'-o',str(binary)],check=True)
 subprocess.run([str(binary)],check=True)
