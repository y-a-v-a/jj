import Foundation

/// Disjoint-set forest with path halving and union by size.
public struct UnionFind: Sendable {
    private var parent: [Int]
    private var size: [Int]
    public private(set) var componentCount: Int

    public init(count: Int) {
        parent = Array(0..<count)
        size = Array(repeating: 1, count: count)
        componentCount = count
    }

    public mutating func find(_ x: Int) -> Int {
        var x = x
        while parent[x] != x {
            parent[x] = parent[parent[x]]
            x = parent[x]
        }
        return x
    }

    /// Merges the sets of `a` and `b`; returns false if they were already joined.
    @discardableResult
    public mutating func union(_ a: Int, _ b: Int) -> Bool {
        var ra = find(a), rb = find(b)
        if ra == rb { return false }
        if size[ra] < size[rb] { swap(&ra, &rb) }
        parent[rb] = ra
        size[ra] += size[rb]
        componentCount -= 1
        return true
    }
}

public enum SpanningTree {
    /// Kruskal's algorithm: the spanning forest of maximum total weight.
    ///
    /// - Parameters:
    ///   - nodeCount: number of nodes (faces of the polyhedron).
    ///   - edges: node pairs (dual edges between faces).
    ///   - weights: weight per edge; heavier edges are kept first. Ties are
    ///     broken by edge index so the result is deterministic.
    /// - Returns: per edge, whether it belongs to the tree.
    public static func maximum(nodeCount: Int, edges: [(Int, Int)], weights: [Double]) -> [Bool] {
        precondition(edges.count == weights.count, "one weight per edge")
        let order = edges.indices.sorted { i, j in
            weights[i] != weights[j] ? weights[i] > weights[j] : i < j
        }
        var sets = UnionFind(count: nodeCount)
        var inTree = Array(repeating: false, count: edges.count)
        for e in order {
            if sets.union(edges[e].0, edges[e].1) {
                inTree[e] = true
                if sets.componentCount == 1 { break }
            }
        }
        return inTree
    }
}

extension SpanningTree {
    /// Prim's algorithm, as van Wijk used it: grow the tree from `root`,
    /// always adding the heaviest edge to a new node. For distinct weights the
    /// result equals `maximum`; ties are broken towards lower edge indices.
    ///
    /// - Parameter incidence: per node, the incident edge indices.
    public static func prim(nodeCount: Int, edges: [(Int, Int)], incidence: [[Int]], weights: [Double], root: Int) -> [Bool] {
        var inTree = Array(repeating: false, count: edges.count)
        var reached = Array(repeating: false, count: nodeCount)
        var heap = EdgeHeap(weights: weights)
        reached[root] = true
        for e in incidence[root] { heap.push(e) }
        var count = 1
        while count < nodeCount, let e = heap.pop() {
            let (a, b) = edges[e]
            let next = reached[a] ? (reached[b] ? -1 : b) : a
            guard next >= 0 else { continue }
            reached[next] = true
            inTree[e] = true
            count += 1
            for f in incidence[next] where !inTree[f] {
                let (c, d) = edges[f]
                if !(reached[c] && reached[d]) { heap.push(f) }
            }
        }
        return inTree
    }
}

/// Binary max-heap of edge indices ordered by weight, then by lower index.
struct EdgeHeap {
    let weights: [Double]
    private var items: [Int] = []

    init(weights: [Double]) { self.weights = weights }

    private func before(_ i: Int, _ j: Int) -> Bool {
        weights[i] != weights[j] ? weights[i] > weights[j] : i < j
    }

    mutating func push(_ e: Int) {
        items.append(e)
        var c = items.count - 1
        while c > 0 {
            let p = (c - 1) / 2
            guard before(items[c], items[p]) else { break }
            items.swapAt(c, p)
            c = p
        }
    }

    mutating func pop() -> Int? {
        guard let top = items.first else { return nil }
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            var p = 0
            while true {
                let l = 2 * p + 1, r = l + 1
                var best = p
                if l < items.count, before(items[l], items[best]) { best = l }
                if r < items.count, before(items[r], items[best]) { best = r }
                if best == p { break }
                items.swapAt(p, best)
                p = best
            }
        }
        return top
    }
}
