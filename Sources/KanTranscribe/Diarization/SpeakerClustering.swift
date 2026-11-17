import Foundation

/// Global speaker clustering of embeddings (WeSpeaker 256-d). Pure and thread-safe.
public enum SpeakerClustering {
    /// Duration-weighted average-linkage agglomerative clustering on cosine similarity.
    ///
    /// Merges the most similar pair until the best similarity drops below `threshold` (and, when
    /// `maxClusters` is set, until at most that many clusters remain). Clusters whose total weight is
    /// below `minClusterWeight` are then folded into the most similar cluster above it. Returns one
    /// label per embedding, numbered 0, 1, … in order of each cluster's first member.
    ///
    /// Rows cache their best partner, so the typical cost is O(n²) for ~1–2 k units.
    public static func agglomerative(_ embeddings: [[Float]], weights: [Double], threshold: Float = 0.55,
                                     minClusterWeight: Double = 0, maxClusters: Int? = nil) -> [Int] {
        let n = embeddings.count
        guard n > 1, weights.count == n else { return [Int](repeating: 0, count: n) }
        let unit = embeddings.map(normalized)
        var similarity = [Float](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in i..<n {
                let value = i == j ? 1 : dot(unit[i], unit[j])
                similarity[i * n + j] = value
                similarity[j * n + i] = value
            }
        }

        var alive = [Bool](repeating: true, count: n)
        var aliveCount = n
        var weight = weights.map { max($0, 1e-6) }
        var members: [[Int]] = (0..<n).map { [$0] }
        var bestPartner = [Int](repeating: -1, count: n)
        var bestValue = [Float](repeating: -.infinity, count: n)

        func refreshRow(_ i: Int) {
            bestPartner[i] = -1
            bestValue[i] = -.infinity
            for j in 0..<n where j != i && alive[j] && similarity[i * n + j] > bestValue[i] {
                bestValue[i] = similarity[i * n + j]
                bestPartner[i] = j
            }
        }
        for i in 0..<n { refreshRow(i) }

        while aliveCount > 1 {
            var a = -1
            for i in 0..<n where alive[i] && bestPartner[i] >= 0 && (a < 0 || bestValue[i] > bestValue[a]) { a = i }
            guard a >= 0 else { break }
            let b = bestPartner[a]
            let mustMerge = maxClusters.map { aliveCount > max(1, $0) } ?? false
            if bestValue[a] < threshold && !mustMerge { break }

            // Lance–Williams update for weighted average linkage; b is merged into a.
            let wa = weight[a], wb = weight[b]
            for k in 0..<n where alive[k] && k != a && k != b {
                let value = Float((wa * Double(similarity[a * n + k]) + wb * Double(similarity[b * n + k])) / (wa + wb))
                similarity[a * n + k] = value
                similarity[k * n + a] = value
            }
            weight[a] = wa + wb
            members[a].append(contentsOf: members[b])
            alive[b] = false
            aliveCount -= 1
            // Only rows whose best partner was a or b can change: an average never exceeds its parts.
            for k in 0..<n where alive[k] && (k == a || bestPartner[k] == a || bestPartner[k] == b) { refreshRow(k) }
        }

        var roots = (0..<n).filter { alive[$0] }
        if minClusterWeight > 0 {
            let big = roots.filter { weight[$0] >= minClusterWeight }
            if !big.isEmpty && big.count < roots.count {
                for root in roots where weight[root] < minClusterWeight {
                    var target = big[0]
                    for candidate in big where similarity[root * n + candidate] > similarity[root * n + target] {
                        target = candidate
                    }
                    members[target].append(contentsOf: members[root])
                }
                roots = big
            }
        }

        var labels = [Int](repeating: 0, count: n)
        let ordered = roots.sorted { (members[$0].min() ?? 0) < (members[$1].min() ?? 0) }
        for (label, root) in ordered.enumerated() {
            for member in members[root] { labels[member] = label }
        }
        return labels
    }

    /// Weighted mean embedding per label, L2-normalized.
    public static func centroids(_ embeddings: [[Float]], weights: [Double], labels: [Int]) -> [Int: [Float]] {
        var sums: [Int: [Double]] = [:]
        for (index, embedding) in embeddings.enumerated() where index < labels.count && index < weights.count {
            var sum = sums[labels[index]] ?? [Double](repeating: 0, count: embedding.count)
            guard sum.count == embedding.count else { continue }
            let w = weights[index]
            for k in embedding.indices { sum[k] += w * Double(embedding[k]) }
            sums[labels[index]] = sum
        }
        return sums.mapValues { normalized($0.map { Float($0) }) }
    }

    public static func normalized(_ vector: [Float]) -> [Float] {
        let norm = dot(vector, vector).squareRoot()
        guard norm > 1e-9 else { return vector }
        return vector.map { $0 / norm }
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        dot(normalized(a), normalized(b))
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var sum: Float = 0
        for k in 0..<min(a.count, b.count) { sum += a[k] * b[k] }
        return sum
    }
}
