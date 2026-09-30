import Foundation

struct CompletionSection: Identifiable {
    var title: String
    var tasks: [Todo]
    var id: String { title }

    static func group(_ tasks: [Todo], now: Date = Date(), calendar: Calendar = .current) -> [CompletionSection] {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let week = calendar.dateInterval(of: .weekOfYear, for: now)!
        let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: week.start)!
        let labels = ["Today", "Yesterday", "This Week", "Last Week", "Earlier", "Completed Earlier"]
        var buckets = Array(repeating: [Todo](), count: labels.count)
        for task in tasks where task.status == "completed" {
            let index: Int
            if let date = task.completedAt {
                if date >= today { index = 0 }
                else if date >= yesterday { index = 1 }
                else if date >= week.start { index = 2 }
                else if date >= lastWeek { index = 3 }
                else { index = 4 }
            } else {
                // Legacy tasks have no completion timestamp; never substitute creation time.
                index = 5
            }
            buckets[index].append(task)
        }
        return labels.indices.compactMap { index in
            guard !buckets[index].isEmpty else { return nil }
            return CompletionSection(title: labels[index], tasks: buckets[index].sorted {
                ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast)
            })
        }
    }
}
