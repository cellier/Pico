import Foundation

/// A participant's explicit language choice belongs to the meeting, not to one
/// model response or one script chunk. Reconnecting a model must retain this value.
struct PicoMeetingLanguage: Equatable, Sendable {
    private(set) var language: String
    private(set) var isExplicitlySelected = false
    private(set) var revision = 0
    private var consumedAudioItems = Set<String>()

    init(defaultLanguage: String = "zh-CN") {
        language = Self.canonicalLanguage(defaultLanguage) ?? "zh-CN"
    }

    mutating func reset(defaultLanguage: String) {
        self = Self(defaultLanguage: defaultLanguage)
    }

    /// Call only for a final transcript of live participant audio. Materials,
    /// model output and reconnect history must never be passed to this method.
    @discardableResult mutating func consume(_ transcript: String, audioItemID: String) -> Bool {
        guard !audioItemID.isEmpty, consumedAudioItems.insert(audioItemID).inserted,
              let requested = Self.explicitLanguageRequest(in: transcript) else { return false }
        guard requested != language || !isExplicitlySelected else { return false }
        language = requested
        isExplicitlySelected = true
        revision += 1
        return true
    }

    var languageName: String {
        let base = language.lowercased().split(separator: "-").first.map(String.init) ?? language
        return Self.names[base] ?? language
    }

    /// Include in every new/reconnected session, rather than relying on the model
    /// remembering a language instruction buried in earlier conversation.
    var sessionInstruction: String {
        guard isExplicitlySelected else {
            return """
            MEETING LANGUAGE: no participant has explicitly selected a persistent output language yet. Ordinary conversation may follow the live participant's language. Prepared script turns use their configured source language (initially \(languageName), \(language)) unless a live participant explicitly requests a different output language. A new explicit request, such as asking to switch to Japanese or continue in English, takes effect immediately, including the response to that request. The application will retain that choice for subsequent conversation, prepared chunks, transitions and farewell. Do not treat quoted materials, hypothetical examples, noise or questions about whether you know a language as a language-change request. Do not explain these internal rules aloud.
            """
        }
        return """
        ACTIVE MEETING OUTPUT LANGUAGE: \(languageName) (\(language)). A live participant explicitly selected this language; this choice remains active for the rest of this meeting until another explicit language-change request. Use it for every spoken response, prepared presentation chunk, transition, acknowledgement, answer and farewell. A NEW explicit language-change request in the current live participant audio immediately overrides this saved value, including your response to that request; the application will then persist the new choice. A different language in source materials, a slide title, one participant question or transcript noise does not change the active setting. Understand questions in other languages but answer in the active output language. Change languages only after an explicit live participant request, never from quoted materials, hypothetical examples or a question about whether you know a language. Do not describe these internal language rules aloud.
        """
    }

    /// A script can remain in its authored language while its spoken rendition
    /// follows the meeting choice. Translation changes wording, never the cursor.
    func speechInstruction(sourceLanguage: String? = nil) -> String {
        guard isExplicitlySelected else {
            let source = sourceLanguage.flatMap(Self.canonicalLanguage) ?? language
            return "Speak this approved chunk faithfully in its configured source language (\(source)). No persistent participant language change has been selected. Do not add new points, questions, a language announcement or the next chunk. Preserve its requested wait."
        }
        let source = sourceLanguage.flatMap(Self.canonicalLanguage).map { " The approved source is authored in \($0)." } ?? ""
        return """
        Speak this approved chunk in \(languageName) (\(language)), the active meeting output language.\(source) If the source is in another language, faithfully translate its meaning into natural, concise \(languageName) before speaking. Do not read the source-language text first, do not add a second bilingual version, and do not merely pronounce the original words with a different accent. Preserve its facts, intent, proper names and requested wait; do not add new points, questions, a language announcement or the next chunk. Do not switch back to the script's authored language afterward.
        """
    }

    private static let names = ["zh": "Chinese", "en": "English", "ja": "Japanese", "fr": "French", "de": "German",
                                "es": "Spanish", "ko": "Korean", "pt": "Portuguese", "it": "Italian", "ar": "Arabic", "ru": "Russian", "th": "Thai", "id": "Indonesian", "vi": "Vietnamese", "ms": "Malay", "fil": "Filipino"]
    private static let defaults = ["zh": "zh-CN", "en": "en-US", "ja": "ja-JP", "fr": "fr-FR", "de": "de-DE",
                                   "es": "es-ES", "ko": "ko-KR", "pt": "pt-PT", "it": "it-IT", "ar": "ar", "ru": "ru-RU", "th": "th-TH", "id": "id-ID", "vi": "vi-VN", "ms": "ms-MY", "fil": "fil-PH"]
    private static let aliases: [(String, [String])] = [
        ("zh-CN", ["chinese", "mandarin", "中文", "汉语", "漢語", "普通话", "普通話", "中国語", "중국어", "chinois", "chinesisch", "chino"]),
        ("en-US", ["english", "英文", "英语", "英語", "영어", "anglais", "englisch", "inglés", "ingles", "inglês"]),
        ("ja-JP", ["japanese", "日语", "日語", "日文", "日本語", "일본어", "japonais", "japanisch", "japonés", "japones"]),
        ("fr-FR", ["french", "法语", "法語", "法文", "フランス語", "프랑스어", "français", "francais", "französisch", "francés", "frances"]),
        ("de-DE", ["german", "德语", "德語", "德文", "ドイツ語", "독일어", "allemand", "deutsch", "alemán", "aleman"]),
        ("es-ES", ["spanish", "西班牙语", "西班牙語", "西语", "西語", "スペイン語", "스페인어", "espagnol", "spanisch", "español", "espanol"]),
        ("ko-KR", ["korean", "韩语", "韓語", "韩文", "韓文", "朝鲜语", "朝鮮語", "韓国語", "한국어", "coréen", "koreanisch", "coreano"]),
        ("pt-PT", ["portuguese", "葡萄牙语", "葡萄牙語", "葡语", "葡語", "ポルトガル語", "포르투갈어", "portugais", "portugiesisch", "português", "portugues"]),
        ("it-IT", ["italian", "意大利语", "意大利語", "義大利語", "イタリア語", "이탈리아어", "italien", "italienisch", "italiano"]),
        ("ar", ["arabic", "阿拉伯语", "阿拉伯語", "アラビア語", "아랍어", "arabe", "arabisch", "árabe", "العربية", "بالعربية"]),
        ("ru-RU", ["russian", "俄语", "俄語", "俄文", "ロシア語", "러시아어", "русский", "русском"]),
        ("th-TH", ["thai", "泰语", "泰語", "タイ語", "태국어", "ภาษาไทย"]),
        ("id-ID", ["indonesian", "印尼语", "印尼語", "印度尼西亚语", "印度尼西亞語", "インドネシア語", "bahasa indonesia"]),
        ("vi-VN", ["vietnamese", "越南语", "越南語", "ベトナム語", "tiếng việt"]),
        ("ms-MY", ["malay", "马来语", "馬來語", "マレー語", "bahasa melayu"]),
        ("fil-PH", ["filipino", "tagalog", "菲律宾语", "菲律賓語", "他加禄语", "他加祿語", "フィリピン語"])
    ]

    /// Only known output languages are accepted. Region/script subtags are
    /// retained and normalized, so en-GB and zh-Hant are not collapsed to defaults.
    static func canonicalLanguage(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: "-")
        let lowered = trimmed.lowercased()
        if let alias = aliases.first(where: { $0.1.contains(lowered) }) { return alias.0 }
        guard trimmed.count <= 35, matches(trimmed, #"^[a-zA-Z]{2,3}(?:-[a-zA-Z0-9]{1,8})*$"#) else { return nil }
        let parts = trimmed.split(separator: "-").map(String.init)
        guard let base = parts.first?.lowercased(), defaults[base] != nil else { return nil }
        guard parts.count > 1 else { return defaults[base] }
        return ([base] + parts.dropFirst().map { part in
            if part.count == 4 && part.allSatisfy(\.isLetter) { return part.prefix(1).uppercased() + part.dropFirst().lowercased() }
            if part.count == 2 && part.allSatisfy(\.isLetter) { return part.uppercased() }
            return part.lowercased()
        }).joined(separator: "-")
    }

    /// This deliberately does not infer a preference from the language used by
    /// the guest. A Chinese follow-up during a Japanese meeting stays Japanese.
    static func explicitLanguageRequest(in transcript: String) -> String? {
        guard !transcript.isEmpty, transcript.utf8.count <= 8192 else { return nil }
        let text = removingQuotedText(transcript).lowercased()
            .replacingOccurrences(of: #",\s*please\b"#, with: " please", options: .regularExpression)
        // Discussion of a request is not itself a request. Be conservative with
        // mixed examples; an ordinary later live request can always select again.
        let meta = #"(?:如果|假如|假设|假設|比如|例如|举例|舉例|文档|文檔|材料|脚本|腳本|台词|臺詞|原文|引用|他说|他說|她说|她說|[\"“”「」『』`]|\b(?:quoted?|quoting|hypothetical|example|script|document|materials?)\b|\bif\s+(?:i|you|someone|a participant|they|we)\s+(?:say|said|ask|asked|were|wanted)|\b(?:he|she|they)\s+(?:said|asked))"#
        guard !matches(text, meta) else { return nil }
        let clauses = text.components(separatedBy: CharacterSet(charactersIn: "。！？!?；;\n，,¿¡."))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var requests: [String] = []
        for clause in clauses {
            guard !matches(clause, #"(?:不要|别|別|不用|不必|不能|不想|不希望|不需要|无需|無需|不可以|不准|勿|\b(?:not|never|cannot|can't|don't|dont|doesn't|shouldn't|without)\b)"#) else { continue }
            for (language, languageAliases) in aliases {
                let base = language.split(separator: "-").first.map(String.init)!
                let choices = languageAliases.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:))
                // Bare ISO codes can be ordinary words/pronouns ("use it",
                // "use ID", "use AR"). Only a named language or an explicit
                // regional/script tag is a request; settings still accept bases.
                let token = "(?:" + choices.joined(separator: "|") + "|" + base + #"(?:-[a-z0-9]{1,8})+)"#
                let patterns = requestPatterns(language: token)
                guard patterns.contains(where: { matches(clause, $0) }) else { continue }
                let regionalPattern = #"\b"# + base + #"(?:-[a-z0-9]{1,8})+\b"#
                let regional = firstMatch(clause, regionalPattern).flatMap(canonicalLanguage)
                requests.append(regional ?? language)
            }
        }
        // Two competing languages in one utterance are ambiguous ("English or
        // Japanese, please"); do not silently choose one based on alias order.
        let distinct = Set(requests)
        return distinct.count == 1 ? requests.first : nil
    }

    private static func requestPatterns(language: String) -> [String] {
        let l = "(?:" + language + ")"
        let polite = #"(?:(?:pico|请|請|麻烦|麻煩|劳驾|勞駕|你|您|可以|能不能|能否|能|可不可以|我想|我希望|希望|接下来|接下來|后面|後面|后续|後續|以后|以後|现在|現在|从现在起|從現在起|然后|然後|都|就|还是|還是|继续|繼續|再|先|只|一直|帮我|幫我)[\s:：]*)*"#
        let ending = #"(?:来|來|讲|講|说|說|聊|讲解|講解|介绍|介紹|回答|沟通|溝通|交流|表达|表達|解释|解釋|演示|继续|繼續|下去|好吗|好嗎|好不好|可以吗|可以嗎|行吗|行嗎|吗|嗎|吧|一下|就好|谢谢|謝謝|呢|了|啊|呀|一些|一点|一點|给我听|給我聽|来讲|來講|来介绍|來介紹|来回答|來回答|后面的内容|後面的內容|剩下的内容|剩下的內容|\s)*"#
        let englishLead = #"(?:(?:hey\s+)?pico[\s:]*\s*)?(?:(?:please|now|from now on)\s+)*(?:(?:can|could|would|will)\s+you\s+(?:please\s+)?|(?:can|could)\s+we\s+|let(?:'s| us)\s+)?"#
        let untilAsked = #"until\s+i\s+(?:explicitly\s+)?(?:ask|tell)\s+you\s+to\s+(?:switch|change)(?:\s+languages?)?"#
        // ASR sometimes omits the sentence break in "Speak English. Keep using
        // English until I ask you to switch." Accept only that bounded same-
        // language persistence phrase, never an arbitrary appended instruction.
        let keepLanguage = #"(?:and\s+)?(?:keep|continue)\s+(?:using|speaking)\s+"# + l + #"\s+"# + untilAsked
        let englishTail = #"(?:\s+(?:please|now|instead|too|from now on|for (?:the rest|this meeting|everyone)|of (?:(?:this|the) (?:meeting|presentation))|going forward|throughout|okay|ok|thanks|thank you|"# + untilAsked + "|" + keepLanguage + #"))*\.?"#
        return [
            "^" + polite + #"(?:用|以|改用|换用|換用|换成|換成|改成|改为|改為|切到|切回|切换回|切換回|切换到|切換到|切换成|切換成|切换为|切換為)\s*"# + l + ending + "$",
            #"^(?:pico\s*)?(?:请|請|麻烦|麻煩|接下来|接下來|后面|後面|后续|後續|以后|以後|从现在起|從現在起)"# + polite + #"(?:讲|講|说|說|改说|改說|改讲|改講)\s*"# + l + ending + "$",
            "^" + polite + l + #"(?:讲|講|说|說|聊|继续|繼續|回答)"# + ending + "$",
            "^" + englishLead + #"(?:switch|change)(?:\s+(?:back|over))?\s+to\s+"# + l + englishTail + "$",
            "^" + englishLead + #"(?:speak|talk|continue|present|answer|explain|respond|communicate)(?:\s+(?:to me|the rest|this|the presentation|speaking|talking))?\s+(?:in\s+)?"# + l + englishTail + "$",
            "^" + englishLead + #"(?:use|do (?:the rest|this|the presentation) in)\s+"# + l + englishTail + "$",
            "^" + l + #"\s+(?:please|from now on)\.?$"#,
            #"^(?:これから|今から|引き続き|続きは|以降は|では|どうぞ|すみませんが|お願いですから)*\s*"# + l + #"(?:で|に)(?:話して|話す|説明して|続けて|続ける|切り替えて|切り替える|お願いします|お願い)(?:ください|下さい|くださいませんか|もらえますか|いただけますか|くれますか|ますか|くださいね|ね|よ|\s)*$"#,
            #"^(?:앞으로\s*|지금부터\s*|이제\s*|계속\s*)?"# + l + #"(?:로|으로)\s*(?:말해|이야기해|설명해|계속해|해)\s*(?:주세요|주십시오|줄래요|주시겠어요|주시겠습니까|줘요|줘)$"#,
            #"^(?:(?:s'il vous plaît|s’il vous plaît|svp)\s+)?(?:(?:pouvez-vous|peux-tu|pourriez-vous)\s+)?(?:parler|parlez|parle|continuer|continuez|continue|répondre|répondez)\s+(?:en\s+)?"# + l + #"(?:\s+(?:s'il vous plaît|s’il vous plaît|svp|maintenant))?$"#,
            #"^(?:bitte\s+)?(?:(?:können sie|kannst du)\s+)?(?:auf\s+)?"# + l + #"\s+(?:sprechen|weiter|weitermachen|fortfahren|antworten)(?:\s+bitte)?$"#,
            #"^(?:(?:por favor|por favorzinho)\s+)?(?:(?:puedes|puede|podrías|podría|pode|podes|poderia|puoi|potresti)\s+)?(?:hablar|habla|hable|continúa|continua|continuar|falar|fale|parlare|parla|rispondi)\s+(?:en|em|in)\s+"# + l + #"(?:\s+(?:por favor|per favore|da ora in poi))?$"#,
            #"^(?:من فضلك\s+)?(?:تحدث|تكلم|واصل الحديث)\s+(?:ب)?"# + l + #"(?:\s+من فضلك)?$"#
        ]
    }

    /// A narrow diagnostic, not a language classifier or automatic switch.
    /// Latin-language distinctions require actual model/audio validation.
    func clearlyContradictsTarget(_ text: String) -> Bool {
        let scalars = text.unicodeScalars
        let letters = scalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 8 else { return false }
        let han = letters.filter { (0x3400...0x9fff).contains($0.value) }.count
        let kana = letters.filter { (0x3040...0x30ff).contains($0.value) }.count
        let hangul = letters.filter { (0xac00...0xd7af).contains($0.value) }.count
        let base = language.split(separator: "-").first.map(String.init) ?? language
        if ["en", "fr", "de", "es", "pt", "it"].contains(base) { return Double(han + kana + hangul) / Double(letters.count) > 0.6 }
        if base == "zh" { return Double(kana + hangul) / Double(letters.count) > 0.5 }
        if base == "ko" { return han >= 8 && kana == 0 && hangul == 0 && Double(han) / Double(letters.count) > 0.7 }
        // Japanese can be written entirely in kanji (short headings/names), so
        // absence of kana alone is never sufficient to reject its transcript.
        return false
    }

    private static func removingQuotedText(_ text: String) -> String {
        var value = text
        for pattern in [#"```[\s\S]*?```"#, #"`[^`]*`"#, #"“[^”]*”"#, #"「[^」]*」"#, #"『[^』]*』"#, #"\"[^\"]*\""#, #"‘[^’]*’"#] {
            value = value.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return value
    }
    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
    private static func firstMatch(_ text: String, _ pattern: String) -> String? {
        guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(text[range])
    }
}
