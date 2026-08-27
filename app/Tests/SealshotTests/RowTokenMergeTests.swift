import XCTest
@testable import Sealshot

/// Word-level merging of the tile fragments that read one line.
///
/// The case that produced this code is `test_fieldCapture_...` below: a
/// full-width sentence read by three overlapping tiles, where re-OCR'ing the
/// merged region returned two partial lines and dropped everything between
/// x=0.321 and x=0.595 — a whole clause the tiles had read at confidence 1.00.
final class RowTokenMergeTests: XCTestCase {

    private static let rowY: CGFloat = 0.34
    private static let rowH: CGFloat = 0.012

    /// A word at an ABSOLUTE position on the row.
    ///
    /// Fixtures must place a shared word at the same coordinates in every
    /// fragment that read it: tile fragments are mapped back to full-image
    /// space before they reach the merge, so the same glyphs always carry the
    /// same x. Building each fragment by uniformly subdividing its own box
    /// breaks that — it puts one word in two places — and no correct merge can
    /// satisfy geometry that could not exist.
    private struct Word {
        let text: String
        let x: CGFloat
        let w: CGFloat
    }

    /// Assemble a fragment from words, giving each character its slice of its
    /// word's box and each separator the gap it actually spans — the same
    /// shape `tokenAwareCharacterBoxes` produces from Vision token geometry.
    private func fragment(_ words: [Word], conf: Float = 1)
        -> (line: RecognizedLine, conf: Float) {
        var text = ""
        var boxes: [CGRect] = []
        for (index, word) in words.enumerated() {
            if index > 0 {
                let previous = words[index - 1]
                let gapStart = previous.x + previous.w
                text.append(" ")
                boxes.append(CGRect(x: gapStart, y: Self.rowY,
                                    width: max(0, word.x - gapStart), height: Self.rowH))
            }
            text += word.text
            let charWidth = word.w / CGFloat(max(word.text.count, 1))
            boxes += (0..<word.text.count).map { i in
                CGRect(x: word.x + CGFloat(i) * charWidth, y: Self.rowY,
                       width: charWidth, height: Self.rowH)
            }
        }
        let box = boxes.reduce(CGRect.null) { $0.union($1) }
        return (RecognizedLine(text: text, box: box, charBoxes: boxes), conf)
    }

    /// The left-hand remnant a tile seam leaves when it cuts through `word`:
    /// the first `chars` characters, occupying exactly the space those glyphs
    /// occupy in the whole word.
    private func leftRemnant(of word: Word, chars: Int) -> Word {
        Word(text: String(word.text.prefix(chars)), x: word.x,
             w: word.w * CGFloat(chars) / CGFloat(word.text.count))
    }

    /// The right-hand remnant, mirroring `leftRemnant`.
    private func rightRemnant(of word: Word, chars: Int) -> Word {
        let dropped = word.text.count - chars
        let charWidth = word.w / CGFloat(word.text.count)
        return Word(text: String(word.text.suffix(chars)),
                    x: word.x + charWidth * CGFloat(dropped),
                    w: charWidth * CGFloat(chars))
    }

    // MARK: - Tokenizing

    func test_rowTokens_splitsOnWhitespace_andUnionsCharBoxes() {
        let f = fragment([Word(text: "ab", x: 0.0, w: 0.2),
                          Word(text: "cd", x: 0.3, w: 0.2)])
        let tokens = rowTokens(of: f.line, conf: f.conf)
        XCTAssertEqual(tokens.map(\.text), ["ab", "cd"])
        XCTAssertEqual(tokens[0].box.minX, 0.0, accuracy: 0.0001)
        XCTAssertEqual(tokens[1].box.maxX, 0.5, accuracy: 0.0001)
    }

    func test_rowTokens_mismatchedCharBoxes_yieldNothing() {
        // Geometry we cannot trust must not be guessed at.
        let line = RecognizedLine(text: "hello", box: CGRect(x: 0, y: 0, width: 0.2, height: 0.01),
                                  charBoxes: [])
        XCTAssertTrue(rowTokens(of: line, conf: 1).isEmpty)
    }

    func test_edgeMargin_measuredFromOwningFragment() {
        let f = fragment([Word(text: "aa", x: 0.2, w: 0.05),
                          Word(text: "bb", x: 0.30, w: 0.05),
                          Word(text: "cc", x: 0.40, w: 0.05)])
        let tokens = rowTokens(of: f.line, conf: f.conf)
        XCTAssertEqual(tokens[0].edgeMargin, 0, accuracy: 0.0001, "first token is flush left")
        XCTAssertEqual(tokens[2].edgeMargin, 0, accuracy: 0.0001, "last token is flush right")
        XCTAssertGreaterThan(tokens[1].edgeMargin, 0, "middle token sits inside")
    }

    // MARK: - Merging

    func test_duplicateWords_collapseToOne() {
        let alpha = Word(text: "alpha", x: 0.00, w: 0.10)
        let beta = Word(text: "beta", x: 0.12, w: 0.08)
        let gamma = Word(text: "gamma", x: 0.22, w: 0.10)
        let merged = mergeRowFragments([fragment([alpha, beta]), fragment([beta, gamma])])
        XCTAssertEqual(merged?.line.text, "alpha beta gamma")
    }

    func test_charBoxCount_matchesMergedText() {
        // Selection indexes into charBoxes by character; a mismatch would
        // highlight the wrong glyphs.
        let alpha = Word(text: "alpha", x: 0.00, w: 0.10)
        let beta = Word(text: "beta", x: 0.12, w: 0.08)
        let gamma = Word(text: "gamma", x: 0.22, w: 0.10)
        let merged = mergeRowFragments([fragment([alpha, beta]), fragment([beta, gamma])])
        XCTAssertEqual(merged?.line.charBoxes.count, merged?.line.text.count)
    }

    func test_seamDebris_losesToTheWholeWord() {
        // The seam cuts "format." after two glyphs: the left tile keeps "fo",
        // the right tile read the whole word with context around it.
        let container = Word(text: "container", x: 0.10, w: 0.18)
        let format = Word(text: "format.", x: 0.30, w: 0.12)
        let thats = Word(text: "Thats", x: 0.44, w: 0.09)

        let left = fragment([container, leftRemnant(of: format, chars: 2)])
        let right = fragment([container, format, thats])

        let merged = mergeRowFragments([left, right])
        XCTAssertEqual(merged?.line.text, "container format. Thats")
    }

    func test_rowEdgeWords_survive_becauseNothingElseReadThem() {
        // The row's true first and last words are flush against the outermost
        // fragment edges, exactly like seam debris. Only a competing read of
        // the same word may displace a token, so these stay.
        let first = Word(text: "first", x: 0.00, w: 0.08)
        let second = Word(text: "second", x: 0.10, w: 0.09)
        let third = Word(text: "third", x: 0.21, w: 0.08)
        let merged = mergeRowFragments([fragment([first, second]), fragment([second, third])])
        XCTAssertEqual(merged?.line.text, "first second third")
    }

    func test_wordSplitAcrossBothTiles_survivesAsAWholeWord() {
        // Both tiles cut the same word, so BOTH reads are edge-flush and each
        // is covered by the other fragment. An earlier version dropped them
        // both and deleted the word; suppression must keep one.
        let word = Word(text: "boundary", x: 0.20, w: 0.16)
        let left = fragment([Word(text: "before", x: 0.05, w: 0.10),
                             leftRemnant(of: word, chars: 5)])
        let right = fragment([rightRemnant(of: word, chars: 5),
                              Word(text: "after", x: 0.40, w: 0.08)])
        let text = mergeRowFragments([left, right])?.line.text
        XCTAssertNotNil(text)
        XCTAssertTrue(text?.contains("boun") ?? false,
                      "the split word vanished entirely: \(text ?? "nil")")
    }

    func test_confidence_isTheWeakestWord() {
        let alpha = Word(text: "alpha", x: 0.00, w: 0.10)
        let beta = Word(text: "beta", x: 0.12, w: 0.08)
        let gamma = Word(text: "gamma", x: 0.22, w: 0.10)
        let merged = mergeRowFragments([fragment([alpha, beta], conf: 0.9),
                                        fragment([beta, gamma], conf: 0.4)])
        XCTAssertEqual(merged?.conf ?? 0, 0.4, accuracy: 0.0001)
    }

    func test_singleFragment_passesThroughUnchanged() {
        let only = fragment([Word(text: "untouched", x: 0.1, w: 0.2)])
        let merged = mergeRowFragments([only])
        XCTAssertEqual(merged?.line.text, "untouched")
        XCTAssertEqual(merged?.line.charBoxes, only.line.charBoxes)
    }

    func test_unusableGeometry_returnsNil_soCallerKeepsFragments() {
        let bad = (RecognizedLine(text: "one", box: CGRect(x: 0, y: 0, width: 0.2, height: 0.01),
                                  charBoxes: []), Float(1))
        XCTAssertNil(mergeRowFragments([bad, bad]))
    }

    // MARK: - The regression that motivated this

    /// The sentence from the field capture, laid out across the row. Tiles are
    /// carved out of this single source of truth, so every fragment agrees
    /// about where each word is — as real fragments do.
    private var sentence: [Word] {
        let texts = ["captures", "real", "Finder", "thumbnails", "via", "a", "single-file",
                     "container", "format.", "Thats", "done", "and", "working;", "the",
                     "fix", "is", "committed", "and", "pushed", "on"]
        var words: [Word] = []
        var x: CGFloat = 0.001
        for text in texts {
            let w = CGFloat(text.count) * 0.0075
            words.append(Word(text: text, x: x, w: w))
            x += w + 0.008
        }
        return words
    }

    private func tile(_ range: ClosedRange<CGFloat>) -> (line: RecognizedLine, conf: Float) {
        fragment(sentence.filter { $0.x >= range.lowerBound && $0.x + $0.w <= range.upperBound })
    }

    func test_fieldCapture_threeTileFragments_keepTheWholeSentence() {
        // Three overlapping tiles, as in the diagnostic log: x[0…0.50],
        // x[0.25…0.75], x[0.50…0.91].
        let merged = mergeRowFragments([tile(0.0...0.50), tile(0.25...0.75), tile(0.50...1.0)])
        let text = merged?.line.text

        // The clause that went missing in the field.
        XCTAssertEqual(text, sentence.map(\.text).joined(separator: " "),
                       "the merged row is not the original sentence")
        // And each word appears exactly once — the point of merging at word
        // level rather than keeping overlapping fragments.
        XCTAssertEqual(text?.components(separatedBy: "single-file").count, 2)
        XCTAssertEqual(text?.components(separatedBy: "thumbnails").count, 2)
    }

    func test_merge_neverNarrowsTheRow() {
        // The invariant the old re-read broke: the merged line must span what
        // the fragments spanned.
        let tiles = [tile(0.0...0.50), tile(0.25...0.75), tile(0.50...1.0)]
        let inputSpan = tiles.map(\.line.box).reduce(CGRect.null) { $0.union($1) }
        let merged = mergeRowFragments(tiles)
        XCTAssertNotNil(merged)
        XCTAssertLessThanOrEqual(merged!.line.box.minX, inputSpan.minX + 0.0001)
        XCTAssertGreaterThanOrEqual(merged!.line.box.maxX, inputSpan.maxX - 0.0001)
    }
}
