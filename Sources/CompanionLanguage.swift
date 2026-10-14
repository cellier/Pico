import Foundation
import NaturalLanguage

enum CompanionLanguage {
    static func detect(_ text:String)->String {
        let value=text.lowercased()
        // Explicit output language takes priority over the utterance's dominant language.
        if value.range(of:"(用|以|请).{0,4}(英语|英文)|(英语|英文).{0,3}(回答|回复)|(?:answer|reply|respond|speak)\\s+(?:to me\\s+)?in english",options:.regularExpression) != nil{return "en"}
        if value.range(of:"(用|以|请).{0,4}中文|中文.{0,3}(回答|回复)|(?:answer|reply|respond|speak)\\s+(?:to me\\s+)?in (?:chinese|mandarin)",options:.regularExpression) != nil{return "zh"}
        let hanCount=text.unicodeScalars.filter{(0x3400...0x9FFF).contains(Int($0.value))}.count
        let wordCount=value.split{!$0.isASCII || !$0.isLetter}.count
        if hanCount>0 && hanCount>=wordCount{return "zh"}
        let recognizer=NLLanguageRecognizer();recognizer.processString(text)
        if let language=recognizer.dominantLanguage {if language == .simplifiedChinese || language == .traditionalChinese{return "zh"};if language == .english{return "en"}}
        let han=text.unicodeScalars.filter{(0x3400...0x9FFF).contains(Int($0.value))}.count
        let englishWords=value.split{!$0.isASCII || !$0.isLetter}.count
        return han>0 && han>=englishWords ? "zh":"en"
    }
}
