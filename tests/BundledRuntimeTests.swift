import Foundation
@main struct RuntimeTests {
 static func main() throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("Telos moved app " + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at:root) }
  let contents=root.appendingPathComponent("Telos.app/Contents")
  try FileManager.default.createDirectory(at:contents.appendingPathComponent("Resources"),withIntermediateDirectories:true)
  let plist:[String:Any] = ["CFBundleIdentifier":"com.telos.runtime-test", "TelosPython":"Runtime/main/bin/python3", "TelosSpeechPython":"Runtime/speech/bin/python3"]
  try PropertyListSerialization.data(fromPropertyList:plist,format:.xml,options:0).write(to:contents.appendingPathComponent("Info.plist"))
  let bundle=Bundle(url:root.appendingPathComponent("Telos.app"))!
  precondition(BundledRuntime.python(bundle:bundle)==contents.appendingPathComponent("Resources/Runtime/main/bin/python3").path)
  precondition(BundledRuntime.python(speech:true,bundle:bundle)==contents.appendingPathComponent("Resources/Runtime/speech/bin/python3").path)
  print("PASS main and speech interpreters follow relocated app with spaces")
 }
}
