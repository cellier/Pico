import Foundation

@main enum ApplicationLocatorTests {
 static func main() throws {
  let files=FileManager.default
  let root=files.temporaryDirectory.appendingPathComponent("PicoApplicationLocator-"+UUID().uuidString,isDirectory:true)
  try files.createDirectory(at:root,withIntermediateDirectories:true)
  defer{try? files.removeItem(at:root)}
  var checks=0
  func expect(_ condition:Bool,_ message:String){precondition(condition,message);checks += 1}
  func app(_ relative:String,id:String="com.telos.mac",executable:Bool=true,permission:Int=0o755)throws->URL {
   let url=root.appendingPathComponent(relative,isDirectory:true)
   try files.createDirectory(at:url.appendingPathComponent("Contents/MacOS"),withIntermediateDirectories:true)
   let info:[String:Any]=["CFBundleIdentifier":id,"CFBundleExecutable":"Pico","CFBundlePackageType":"APPL"]
   try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:url.appendingPathComponent("Contents/Info.plist"))
   if executable {
    let binary=url.appendingPathComponent("Contents/MacOS/Pico")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to:binary)
    try files.setAttributes([.posixPermissions:permission],ofItemAtPath:binary.path)
   }
   return url
  }

  let canonical=try app("current/Pico.app")
  let backup=try app("backup/Telos.app")
  let override=try app("custom/Main.app")
  let wrongID=try app("wrong/Pico.app",id:"local.original.sprout")
  let missingBinary=try app("incomplete/Pico.app",executable:false)
  let notExecutable=try app("not-executable/Pico.app",permission:0o644)
  let absent=root.appendingPathComponent("missing/Telos.app")
  expect(TelosApplication.isMainApplication(canonical),"A main app with an executable should be accepted")
  expect(!TelosApplication.isMainApplication(wrongID),"A different app must not be launched")
  expect(!TelosApplication.isMainApplication(missingBinary),"An incomplete bundle must not be launched")
  expect(!TelosApplication.isMainApplication(notExecutable),"A non-executable file must not be launched")
  expect(!TelosApplication.isMainApplication(absent),"A deleted bundle must not be launched")
  expect(TelosApplication.resolve(locations:.init(explicit:[override],running:[canonical],installed:[backup]))==override,"A valid explicit location should take precedence")
  expect(TelosApplication.resolve(locations:.init(explicit:[absent,wrongID],running:[canonical],installed:[backup]))==canonical,"An invalid override should fall back to the running main app")
  expect(TelosApplication.resolve(locations:.init(running:[canonical],installed:[backup]))==canonical,"The current running app should beat an installed backup")
  expect(TelosApplication.resolve(locations:.init(running:[absent],installed:[canonical]))==canonical,"A stale running path should not block an installed app")
  expect(TelosApplication.resolve(locations:.init(installed:[absent,backup]))==backup,"A valid legacy Telos app remains supported")
  expect(TelosApplication.resolve(locations:.init(installed:[absent],registered:[canonical]))==canonical,"A verified registered app is a final fallback")
  expect(TelosApplication.resolve(locations:.init(explicit:[absent],running:[missingBinary],installed:[wrongID],registered:[notExecutable]))==nil,"No usable app should return nil instead of a nonexistent fallback")

  // Both requests use the same candidate list; only the real filesystem changes.
  let old=try app("rename/Telos.app")
  let renamed=root.appendingPathComponent("rename/Pico.app")
  let sameLocations=TelosApplication.Locations(installed:[renamed,old])
  expect(TelosApplication.resolve(locations:sameLocations)==old,"The original name should resolve before a rename")
  try files.moveItem(at:old,to:renamed)
  expect(TelosApplication.resolve(locations:sameLocations)?.path==renamed.path,"A later action must resolve the renamed app, not cache the deleted old path")
  try files.removeItem(at:renamed)
  expect(TelosApplication.resolve(locations:sameLocations)==nil,"An app removed after a successful request should not be reused")

  let companion=root.appendingPathComponent("repo/Pico/build/Sprout.app")
  let home=root.appendingPathComponent("home")
  let installed=TelosApplication.installedCandidates(bundle:companion,home:home)
  expect(installed.first==root.appendingPathComponent("repo/build/Pico.app"),"A companion built in the repo should find the renamed main app")
  expect(installed.contains(root.appendingPathComponent("repo/build/Telos.app")),"Installed candidates must keep the legacy name as a fallback")

  let enclosing=try app("nested/Renamed Pico.app")
  let embedded=enclosing.appendingPathComponent("Contents/Helpers/Pico Desktop.app")
  try files.createDirectory(at:embedded,withIntermediateDirectories:true)
  expect(TelosApplication.enclosingMainApplication(bundle:embedded)==enclosing,"A moved or renamed host must be resolved from its embedded helper")
  expect(TelosApplication.enclosingMainApplication(bundle:enclosing.appendingPathComponent("Contents/Resources/Pico Desktop.app"))==nil,"An arbitrary resource app must not imply an enclosing host")
  expect(TelosApplication.enclosingMainApplication(bundle:wrongID.appendingPathComponent("Contents/Helpers/Pico Desktop.app"))==nil,"An enclosing app with another identity must not be used")
  expect(TelosApplication.enclosingMainApplication(bundle:companion)==nil,"A standalone character must retain the ordinary discovery path")
  expect(TelosApplication.resolve(locations:.init(installed:[TelosApplication.enclosingMainApplication(bundle:embedded)!,backup]))==enclosing,"The exact embedded host must beat an installed backup")

  let hostEnvironment=["PICO_MANAGED_BY_MAIN":"1","PICO_MAIN_PID":"12345","PICO_APP_PATH":enclosing.path,
                       "PICO_COMPANION_ROOT":root.appendingPathComponent("isolated/companion-v1").path]
  let host=PicoManagedCompanionHost.load(environment:hostEnvironment)!
  expect(host.applicationURL==enclosing && host.companionRoot.path==hostEnvironment["PICO_COMPANION_ROOT"],"A managed launch must use its exact host and isolated IPC root")
  expect(host.matchesOwner(processIdentifier:12345,bundleIdentifier:"com.telos.mac",bundleURL:enclosing),"The expected host process should match")
  expect(!host.matchesOwner(processIdentifier:12346,bundleIdentifier:"com.telos.mac",bundleURL:enclosing),"A different process must not own this character")
  expect(!host.matchesOwner(processIdentifier:12345,bundleIdentifier:"other.app",bundleURL:enclosing),"The owner bundle identifier must match")
  expect(!host.matchesOwner(processIdentifier:12345,bundleIdentifier:"com.telos.mac",bundleURL:backup),"Another Pico checkout must not own this character")
  expect(PicoManagedCompanionHost.load(environment:[:])==nil,"Standalone launches must not become managed implicitly")
  for (key,value) in [("PICO_MAIN_PID","0"),("PICO_MAIN_PID","-1"),("PICO_MAIN_PID","invalid"),
                      ("PICO_APP_PATH",wrongID.path),("PICO_COMPANION_ROOT","relative/companion-v1")]{
   var invalid=hostEnvironment;invalid[key]=value
   expect(PicoManagedCompanionHost.load(environment:invalid)==nil,"Invalid managed launch field must be rejected: "+key)
  }

  let directoryBinary=try app("directory-binary/Pico.app",executable:false)
  try files.createDirectory(at:directoryBinary.appendingPathComponent("Contents/MacOS/Pico"),withIntermediateDirectories:true)
  expect(!TelosApplication.isMainApplication(directoryBinary),"A directory with executable access is not an executable file")
  print("ApplicationLocator: \(checks) filesystem checks passed")
 }
}
