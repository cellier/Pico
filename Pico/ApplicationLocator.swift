import Cocoa

/// The desktop companion can outlive a rename or replacement of the main app.
/// Resolve a verified bundle for each action instead of keeping its old location.
enum TelosApplication {
 struct Locations {
  var explicit:[URL] = []
  var running:[URL] = []
  var installed:[URL] = []
  var registered:[URL] = []
 }

 static func resolve()->URL? {
  let environment=ProcessInfo.processInfo.environment
  let explicit=["PICO_APP_PATH","TELOS_APP_PATH"].compactMap{key->URL? in
   guard let path=environment[key],!path.isEmpty else{return nil}
   return URL(fileURLWithPath:(path as NSString).expandingTildeInPath)
  }
  let workspace=NSWorkspace.shared
  let running=workspace.runningApplications.filter{$0.bundleIdentifier=="com.telos.mac"}.compactMap(\.bundleURL)
  return resolve(locations:Locations(
   explicit:explicit,
   running:running,
   installed:[enclosingMainApplication(bundle:Bundle.main.bundleURL)].compactMap{$0}
    + installedCandidates(bundle:Bundle.main.bundleURL,home:FileManager.default.homeDirectoryForCurrentUser),
   registered:[workspace.urlForApplication(withBundleIdentifier:"com.telos.mac")].compactMap{$0}
  ))
 }

 /// A bundled desktop helper belongs to this exact enclosing app, even after
 /// the user moves or renames Pico. Do not infer a parent from an arbitrary app.
 static func enclosingMainApplication(bundle:URL)->URL? {
  let helper=bundle.standardizedFileURL
  let helpers=helper.deletingLastPathComponent()
  let contents=helpers.deletingLastPathComponent()
  let parent=contents.deletingLastPathComponent()
  guard helpers.lastPathComponent == "Helpers", contents.lastPathComponent == "Contents",
   helpers == parent.appendingPathComponent("Contents/Helpers").standardizedFileURL,
   isMainApplication(parent) else{return nil}
  return parent
 }

 /// Injectable locations keep filesystem regressions independent of Launch Services.
 static func resolve(locations:Locations)->URL? {
  var seen=Set<String>()
  for candidate in locations.explicit+locations.running+locations.installed+locations.registered {
   let url=candidate.standardizedFileURL
   guard seen.insert(url.path).inserted else{continue}
   if isMainApplication(url){return url}
  }
  return nil
 }

 static func installedCandidates(bundle:URL,home:URL)->[URL] {
  let buildDirectory=bundle.deletingLastPathComponent()
  let repository=buildDirectory.deletingLastPathComponent().deletingLastPathComponent()
  return ["Pico.app","Telos.app"].flatMap{name in [
   repository.appendingPathComponent("build").appendingPathComponent(name),
   buildDirectory.appendingPathComponent(name),
   home.appendingPathComponent("Applications").appendingPathComponent(name),
   URL(fileURLWithPath:"/Applications").appendingPathComponent(name)
  ]}
 }

 static func isMainApplication(_ url:URL)->Bool {
  guard url.isFileURL,
   let data=try? Data(contentsOf:url.appendingPathComponent("Contents/Info.plist")),
   let info=(try? PropertyListSerialization.propertyList(from:data,options:[],format:nil)) as? [String:Any],
   info["CFBundleIdentifier"] as? String == "com.telos.mac",
   let name=info["CFBundleExecutable"] as? String,!name.isEmpty,
   (name as NSString).lastPathComponent==name,name != ".",name != ".."
  else{return false}
  let executable=url.appendingPathComponent("Contents/MacOS").appendingPathComponent(name)
  var directory:ObjCBool=false
  return FileManager.default.fileExists(atPath:executable.path,isDirectory:&directory)
   && !directory.boolValue && FileManager.default.isExecutableFile(atPath:executable.path)
 }
}

/// The main app owns the embedded character's lifecycle. Keeping its existing
/// bundle identifier preserves the character's saved skin and voice switches.
struct PicoManagedCompanionHost {
 static let managedKey="PICO_MANAGED_BY_MAIN"
 static let hideNotification=Notification.Name("com.telos.mac.desktopCompanion.hide")
 let processIdentifier:pid_t
 let applicationURL:URL
 let companionRoot:URL

 static func load(environment:[String:String]=ProcessInfo.processInfo.environment)->Self? {
  guard environment[managedKey] == "1",
   let rawPID=environment["PICO_MAIN_PID"],let pid=pid_t(rawPID),pid>0,
   let path=environment["PICO_APP_PATH"],path.hasPrefix("/"),
   let root=environment["PICO_COMPANION_ROOT"],root.hasPrefix("/"),!root.isEmpty else{return nil}
  let app=URL(fileURLWithPath:path).standardizedFileURL
  guard TelosApplication.isMainApplication(app) else{return nil}
  return Self(processIdentifier:pid,applicationURL:app,
              companionRoot:URL(fileURLWithPath:root,isDirectory:true).standardizedFileURL)
 }

 func matchesOwner(processIdentifier:pid_t,bundleIdentifier:String?,bundleURL:URL?)->Bool {
  processIdentifier == self.processIdentifier && bundleIdentifier == "com.telos.mac"
   && bundleURL?.standardizedFileURL == applicationURL
 }

 func ownerIsRunning()->Bool {
  guard let owner=NSRunningApplication(processIdentifier:processIdentifier),!owner.isTerminated else{return false}
  return matchesOwner(processIdentifier:owner.processIdentifier,bundleIdentifier:owner.bundleIdentifier,bundleURL:owner.bundleURL)
 }
}
