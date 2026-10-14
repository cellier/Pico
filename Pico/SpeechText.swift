import Foundation

enum SpeechText {
    static func prepare(_ input:String)->String {
        input.replacingOccurrences(of:"```[^\\n]*\\n",with:"",options:.regularExpression)
            .replacingOccurrences(of:"```",with:"")
            .replacingOccurrences(of:"\\[([^]]+)\\]\\([^)]+\\)",with:"$1",options:.regularExpression)
            .replacingOccurrences(of:"(?m)^\\s{0,3}#{1,6}\\s+",with:"",options:.regularExpression)
            .replacingOccurrences(of:"**",with:"")
            .replacingOccurrences(of:"`",with:"")
            .trimmingCharacters(in:.whitespacesAndNewlines)
    }
    // Preserve every character, including paragraph separators and the final short tail.
    static func chunks(_ text:String,limit:Int=360)->[String] {
        precondition(limit>0)
        var rest=text[...],result=[String]()
        while !rest.isEmpty {
            var end=rest.index(rest.startIndex,offsetBy:limit,limitedBy:rest.endIndex) ?? rest.endIndex
            if end != rest.endIndex {
                let candidate=rest[..<end]
                if let boundary=candidate.lastIndex(where:{$0.isWhitespace || "。！？.!?".contains($0)}),candidate.distance(from:candidate.startIndex,to:boundary)>limit/2 {end=rest.index(after:boundary)}
            }
            result.append(String(rest[..<end]));rest=rest[end...]
        }
        return result
    }
}
