let domain="local.pico.skin-tests.\(UUID().uuidString)"
let defaults=UserDefaults(suiteName:domain)!
defer{defaults.removePersistentDomain(forName:domain)}
precondition(PetSkin.load(from:defaults) == .snowball,"new installations default to White Balloon")
precondition(PetSkin.allCases.map(\.rawValue) == ["classic","blossom","snowball"],"all three skins remain available in menu order")
defaults.set("unchanged-voice-preference",forKey:"voice-test-sentinel")
for skin in PetSkin.allCases {
 skin.save(to:defaults)
 defaults.synchronize()
 let reopened=UserDefaults(suiteName:domain)!
 precondition(PetSkin.load(from:reopened) == skin,"skin survives a fresh preference reader")
 precondition(reopened.string(forKey:PetSkin.preferenceKey) == skin.rawValue)
 precondition(reopened.string(forKey:"voice-test-sentinel") == "unchanged-voice-preference","skin must not reset voice preferences")
 precondition(skin.script == "window.sprout?.setSkin('\(skin.rawValue)')")
}
for invalid:Any in ["unknown", "blossom');malicious()", "", 7, ["blossom"], true] {
 defaults.set(invalid,forKey:PetSkin.preferenceKey)
 precondition(PetSkin.load(from:defaults) == .snowball,"invalid preferences safely fall back to White Balloon")
}
PetSkin.snowball.save(to:defaults)
precondition(PetSkin.load(from:defaults) == .snowball,"a valid choice repairs an invalid saved value")
defaults.removeObject(forKey:PetSkin.preferenceKey)
precondition(PetSkin.load(from:defaults) == .snowball,"removing the preference restores White Balloon")
print("PASS: default White Balloon, valid Classic/Blossom/Snowball choices preserved, invalid values fall back to White Balloon, unrelated preferences preserved, exact JS API")
