// The Swift Programming Language
// https://docs.swift.org/swift-book
// 
// Swift Argument Parser
// https://swiftpackageindex.com/apple/swift-argument-parser/documentation

import ArgumentParser
import Foundation


typealias FileStemsToURLsAndTitlesMapping = [String: (URL, String?)]

enum ConversionError: Error {
    case unknownFileReference(name: String)
}


@main
struct swift_book_offline: AsyncParsableCommand {

    @Argument(help: "The path to the swift-book repository working copy")
    var bookPath: String

    @Option(help: "The path to the pandoc executable")
    var pandocPath: String

    @Option(help: "The output path for the PDF file")
    var outputPathPdf: String = "The-Swift-Programming-Language.pdf"

    @Option(help: "The output path for the ePUB file")
    var outputPathEpub: String = "The-Swift-Programming-Language.epub"

    @Flag(help: "Just preprocess the markdown content, don't produce final output")
    var preprocessMarkdownOnly: Bool = false

    func run() async throws {
        let bookURL = NSURL(fileURLWithPath: (bookPath as NSString).expandingTildeInPath as String)
        let pandocURL = NSURL(fileURLWithPath: (pandocPath as NSString).expandingTildeInPath as String)
        let outputURLPdf = NSURL(fileURLWithPath: (outputPathPdf as NSString).expandingTildeInPath as String)
        let outputURLEpub = NSURL(fileURLWithPath: (outputPathEpub as NSString).expandingTildeInPath as String)

        try await BookConverter().generateOutput(
            bookURL: bookURL as URL,
            pandocURL: pandocURL as URL,
            outputURLPdf: outputURLPdf as URL,
            outputURLEpub: outputURLEpub as URL,
            preprocessMarkdownOnly: preprocessMarkdownOnly)
    }
}


struct BookConverter {

    func generateOutput(bookURL: URL, pandocURL: URL, outputURLPdf: URL, outputURLEpub: URL, preprocessMarkdownOnly: Bool) async throws {
        let combinedMarkdownURL = try await combineAndRewriteMarkdownFiles(bookURL: bookURL, pandocURL: pandocURL)
        print("Preprocessed Markdown content written to \(combinedMarkdownURL.path())")

        if preprocessMarkdownOnly {
            return
        }

        let commonOptions = [
            "--from", "markdown",
            combinedMarkdownURL.path(),
            "--resource-path", bookURL.appending(component: "TSPL.docc/Assets").path(),
            "--highlight-style", "tspl-code-highlight.theme",
            "--standalone",
            "--lua-filter", "rewrite-retina-image-references.lua",
        ]

        var optionSets = [[String]]()

        let ePubOptions = [
            "--to", "epub3",
            "--toc",
            "--split-level=2",
            "--epub-embed-font=/Library/Fonts/SF-Pro-Text-Regular.otf",
            "--epub-embed-font=/Library/Fonts/SF-Pro-Text-RegularItalic.otf",
            "--epub-embed-font=/Library/Fonts/SF-Pro-Text-Bold.otf",
            "--epub-embed-font=/Library/Fonts/SF-Pro-Text-BoldItalic.otf",
            "--epub-embed-font=/Library/Fonts/SF-Mono.ttc",
            "--css", "tspl-epub.css",
            "--output", outputURLEpub.path(),
        ]
        optionSets.append(commonOptions + ePubOptions)

        let pdfOptions = [
            "--to", "pdf",
            "--pdf-engine", "lualatex",
            "--variable", "linkcolor=[HTML]{de5d43}",
            "--template", "tspl-pandoc-template",
            "--output", outputURLPdf.path(),
        ]
        optionSets.append(commonOptions + pdfOptions)

        for options in optionSets {
            try stdoutForSubprocess(executablePath: pandocURL.path(), arguments: options)
        }
    }

    func combineAndRewriteMarkdownFiles(bookURL: URL, pandocURL: URL) async throws-> URL {
        // Preprocess the main md file that pulls in all the per-chapter files and shift up its headings by
        // two levels. We want to get the few headings ("Language Guide", "Language Reference" etc.) that introduce
        // related sets of chapters up to level 1, so that they become the toplevel heading structure visible in
        // the table of contents.
        let mainFilePath = bookURL.appending(component: "TSPL.docc/The-Swift-Programming-Language.md").path()
        let args = ["--from", "markdown", "--to", "markdown", mainFilePath, "--shift-heading-level-by=-2"]
        let mainFileMarkdownText = try stdoutForSubprocess(executablePath: pandocURL.path(), arguments: args)

        // This preprocessing step of the main file performs the inclusion of all referenced
        // per-chapter files, resulting in one large markdown file that contains all content,
        // which we then run through pandoc.
        let combinedBookMarkdownLines = try await preprocessMainFileMarkdown(bookURL: bookURL, pandocURL: pandocURL, mainFileMarkdownText: mainFileMarkdownText)
        let combinedMarkdownURL = URL(filePath: "swiftbook-combined.md")
        try combinedBookMarkdownLines.joined(separator: "\n").write(to: combinedMarkdownURL, atomically: true, encoding: .utf8)
        return combinedMarkdownURL
    }

    private let docInclusionRegex = /^-\s*`<doc:(\w+)>`.*$/
    func preprocessMainFileMarkdown(bookURL: URL, pandocURL: URL, mainFileMarkdownText: String) async throws -> [String] {
        // The DocC inclusion directives as well as cross-references refer to the per-chapter
        // files with the "stem", the filename without extension. We need to be able to map
        // from those stems to the full file paths and also to the human-readable document
        // titles for each file, so build a mapping here that we can then pass around.
        let urlsAndTitlesMapping = try await bookMarkdownFileStemsToURLsAndTitlesMapping(bookURL: bookURL)

        // combinedBookMarkdownLines is where we accumulate all lines of the big combined
        // markdown file. We start it out with a YAML header section that lets us control
        // many details of the pandoc conversion.
        var combinedBookMarkdownLines = [String]()
        combinedBookMarkdownLines.append(contentsOf: try await markdownHeaderLines(bookURL: bookURL))

        // Because of the heading level shifting we performed earlier on the main file,
        // there will be some paragraphs that were formerly headings that we no longer need.
        // This state machine skips over that content until we reach the first heading and then
        // starts processing the DocC <doc:... include directives.

        enum ParserState {        
            case waitingForFirstLine
            case processingDocumentIncludes
        }

        var state = ParserState.waitingForFirstLine
        for line in splitLines(mainFileMarkdownText) {
            switch state {
                case .waitingForFirstLine:
                    if line.hasPrefix("# ") {
                        state = .processingDocumentIncludes
                        combinedBookMarkdownLines.append(line)
                    }
                case .processingDocumentIncludes:
                    if let match = line.firstMatch(of: docInclusionRegex) {
                        // We found a chapter include directive, process and add
                        // the lines of the referenced file at this point
                        let markdownFileToIncludeStem = String(match.1)
                        combinedBookMarkdownLines.append(contentsOf: try linesForIncludedDocument(markdownFileStem: markdownFileToIncludeStem, urlsAndTitlesMapping: urlsAndTitlesMapping, bookURL: bookURL))
                        continue
                    }

                    // The line is something else, add it to the combined output unchanged
                    if line.hasPrefix("# ") {
                        combinedBookMarkdownLines.append("\\newpage{}")
                    }
                    combinedBookMarkdownLines.append(line)
            }
        }

        return combinedBookMarkdownLines
    }

    func linesForIncludedDocument(markdownFileStem: String, urlsAndTitlesMapping: FileStemsToURLsAndTitlesMapping, bookURL: URL) throws -> [String] {
        guard let markdownFileURL = urlsAndTitlesMapping[markdownFileStem]?.0 else {
            throw ConversionError.unknownFileReference(name: markdownFileStem)
        }
        var text = try! String(contentsOf: markdownFileURL, encoding: .utf8)
        // TODO: remove this regex processing after non-well-formed HTML comments
        // (containing double dashes) are fixed in the upstream book sources
        text = text.replacing(/<!--.+?-->/.dotMatchesNewlines(), with: "")
        var lines = splitLines(text)
        
        lines = try rewriteDoccMarkdownChapterFileForPandoc(markdownLines: lines, urlsAndTitlesMapping: urlsAndTitlesMapping, bookURL: bookURL)

        // This enforces a page break after a chapter for PDF output and 
        // it doesn't seem to negatively impact the ePUB output.
        return ["\\newpage{}"] + lines + [""]
    }

    private let definitionListRegex = /^- term (.+):/
    private let whitespaceLineStartRegex = /^\s+/
    func rewriteDoccMarkdownChapterFileForPandoc(markdownLines: [String], urlsAndTitlesMapping: FileStemsToURLsAndTitlesMapping, bookURL: URL) throws -> [String] {

        enum ParserState {        
            case start
            case startDefinitionList
            case readingDefinitionListDefinitionFirstLine
            case readingDefinitionListDefinition
        }

        var state = ParserState.start
        var pushback: String?
        var out = [String]()
        var markdownLines = markdownLines

        while !markdownLines.isEmpty || pushback != nil {
            var line: String
            if pushback != nil {
                line = pushback!
                pushback = nil
            } else {
                line = try rewriteDoccMarkdownLineForPandoc(markdownLines.remove(at: 0), urlsAndTitlesMapping: urlsAndTitlesMapping, bookURL: bookURL)
            }

            switch state {
                case .start:
                    if let match = line.firstMatch(of: definitionListRegex) {
                        out.append(String(match.1))
                        state = .startDefinitionList
                    } else {
                        out.append(line)
                    }
                case .startDefinitionList:
                    out.append("")
                    pushback = line
                    state = .readingDefinitionListDefinitionFirstLine
                case .readingDefinitionListDefinitionFirstLine:
                    out.append(":    \(line.trimmingCharacters(in: .whitespaces))")
                    state = .readingDefinitionListDefinition
                case .readingDefinitionListDefinition:
                    if line.isEmpty {
                        out.append("")
                    } else if line.contains(whitespaceLineStartRegex) {
                        out.append("    \(line.trimmingCharacters(in: .whitespaces))")
                    } else {
                        state = .start
                        pushback = line
                    }
            }
        }

        return out
    }

    // This function performs all rewriting that can be done within a single line.
    // More complex multi-line rewriting should happen in the state machine that this is called from.
    func rewriteDoccMarkdownLineForPandoc(_ line: String, urlsAndTitlesMapping: FileStemsToURLsAndTitlesMapping, bookURL: URL) throws -> String {
        var line = rewriteDoccMarkdownLineForPandocInternalReferences(line, urlsAndTitlesMapping: urlsAndTitlesMapping)
        line = rewriteDoccMarkdownLineForPandocOptionalityMarker(line)
        line = try rewriteDoccMarkdownLineForPandocImageReference(line, bookURL: bookURL)
        line = rewriteDoccMarkdownLineForPandocHeadingLevelShift(line)
        return line
    }

    private let internalReferenceRegex = /<doc:([\w#-]+)>/
    func rewriteDoccMarkdownLineForPandocInternalReferences(_ line: String, urlsAndTitlesMapping: FileStemsToURLsAndTitlesMapping) -> String {
        return line.replacing(internalReferenceRegex) { match     in
            let reference = String(match.1)
            var humanReadableLabel: String
            if reference.contains("#") {
                let items = reference.split(separator: "#")
                let section = items[1]
                humanReadableLabel = String(section.replacing("-", with: " "))
            } else {
                humanReadableLabel = String(urlsAndTitlesMapping[reference]!.1!)
            }
            let identifier = humanReadableLabel.lowercased().replacing(" ", with: "-")
            return "[\(humanReadableLabel)](#\(identifier))"
        }
    }

    private let optionalityMarkerRegex = /(\*{1,2})_\?_/
    func rewriteDoccMarkdownLineForPandocOptionalityMarker(_ line: String) -> String {
        // This fixes the markup used for ? optionality
        // markers used in grammar blocks
        return line.replacing(optionalityMarkerRegex) { match in 
            return "?\(match.1)"
        }
    }

    private let imageReferenceRegex = /!\[([^\]]*)\]\(([\w-]+)\)/
    private let fileOutputRegex = /PNG image data, (\d+) x \d+/
    func rewriteDoccMarkdownLineForPandocImageReference(_ line: String, bookURL: URL) throws -> String {
        guard let match: Regex<Regex<(Substring, Substring, Substring)>.RegexOutput>.Match = line.firstMatch(of: imageReferenceRegex) else {
            return line
        }
        let (caption, imageFilenamePrefix) = (match.1, match.2)
        let imageFilename = "\(imageFilenamePrefix)@2x.png"
        let imageURL = bookURL.appending(component: "TSPL.docc/Assets").appending(component: imageFilename)
        assert(FileManager().fileExists(atPath: imageURL.path()))

        let output = try stdoutForSubprocess(executablePath: "/usr/bin/file", arguments: [imageURL.path()])
        let fileCommandOutputMatch = output.firstMatch(of: fileOutputRegex)!
        let width = Float(fileCommandOutputMatch.1)!
        // Dividing the width by two and then dividing that by about 760
        // gives us the scale factor that will match the image presentation
        // in the online web version.
        let scalePercentage = Int(width / 2 / 7.6)
        return "![\(caption)](\(imageFilename)){ width=\(scalePercentage)% }"
    }    


    private let headingRegex = /^(#+ .+)/
    func rewriteDoccMarkdownLineForPandocHeadingLevelShift(_ line: String) -> String {
        if let match = line.firstMatch(of: headingRegex) {
            // We need to shift down the heading levels for each included
            // per-chapter markdown file by one level so they line up with
            // the headings in the main file.
            return "#\(match.1)"
        }
        return line
    }

    func markdownHeaderLines(bookURL: URL) async throws -> [String] {
        let firstLevel1Heading = try await titleFromFirstLevel1HeadingInMarkdownFile(markdownFileURL: bookURL.appending(component: "TSPL.docc/The-Swift-Programming-Language.md"))!
        let (_, timestamp) = try gitTagOrRefForBookWorkingCopyURL(bookURL: bookURL)!

        return splitLines("""
            ---
            title: \(firstLevel1Heading)
            date: "\(timestamp)"
            toc: true
            toc-depth: 4
            toc-own-page: true
            titlepage: true
            titlepage-rule-color: "de5d43"
            strip-comments: true
            sansfont: "SF Pro Text Heavy"
            mainfont: "SF Pro Text"
            mainfontfallback:
            - "Apple Color Emoji:mode=harf"
            - "Helvetica Neue:mode=harf"
            monofont: "Menlo"
            monofontoptions:
            - "Scale=0.9"
            monofontfallback:
            - "Sathu:mode=harf"
            - "Al Nile:mode=harf"        
            - "Apple Color Emoji:mode=harf"
            - "Apple SD Gothic Neo:mode=harf"
            - "Hiragino Sans:mode=harf"
            fontsize: "10pt"
            listings-disable-line-numbers: true
            listings-no-page-break: false
            papersize: letter
            ---
            """)
    }

    func gitTagOrRefForBookWorkingCopyURL(bookURL: URL) throws -> (String, String)? {
        var cmd = ["git", "-C", bookURL.path(), "tag", "--points-at", "HEAD"]
        var stdout = try stdoutForSubprocess(executablePath: "/usr/bin/env", arguments: cmd)
        if let tag = splitLines(stdout).first, tag.count > 0 {
            cmd = ["git", "-C", bookURL.path(), "for-each-ref", "--format", "%(taggerdate:short)", "refs/tags/\(tag)"]
            stdout = try stdoutForSubprocess(executablePath: "/usr/bin/env", arguments: cmd)
            let timestamp = splitLines(stdout).first!
            return (tag, timestamp)
        }
        
        cmd = ["git", "-C", bookURL.path(), "symbolic-ref", "--short", "HEAD"]
        stdout = try stdoutForSubprocess(executablePath: "/usr/bin/env", arguments: cmd)
        if let ref = splitLines(stdout).first, ref.count > 0 {
            cmd = ["git", "-C", bookURL.path(), "show", "--no-patch", "--pretty=format:%cs", ref]
            stdout = try stdoutForSubprocess(executablePath: "/usr/bin/env", arguments: cmd)
            let timestamp = splitLines(stdout).first!
            return (ref, timestamp)
        }
        
        return nil
    }

    func bookMarkdownFileStemsToURLsAndTitlesMapping(bookURL: URL) async throws -> FileStemsToURLsAndTitlesMapping {
        var mapping = FileStemsToURLsAndTitlesMapping()
        let enumerator = FileManager.default.enumerator(at: bookURL, includingPropertiesForKeys: [.nameKey])
        
        while let itemURL = enumerator?.nextObject() as? URL {
            if itemURL.pathExtension == "md" {
                let stem = itemURL.deletingPathExtension().lastPathComponent
                mapping[stem] = (itemURL, try await titleFromFirstLevel1HeadingInMarkdownFile(markdownFileURL: itemURL))

            }

        }
        
        return mapping
    }

    func titleFromFirstLevel1HeadingInMarkdownFile(markdownFileURL: URL) async throws -> String? {
        for try await line in markdownFileURL.lines {
            if line.starts(with: "# ") {
                return String(line.dropFirst(2).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil;
    }

    @discardableResult
    func stdoutForSubprocess(executablePath: String, arguments: [String]) throws -> String {
        let subProcess = Process()
        let subProcessPipe = Pipe()
        subProcess.currentDirectoryURL = URL(fileURLWithPath: ".")
        subProcess.executableURL = URL(fileURLWithPath: executablePath)
        subProcess.arguments = arguments
        subProcess.standardOutput = subProcessPipe
        try subProcess.run()
        let processOutput = subProcessPipe.fileHandleForReading.readDataToEndOfFile()
        subProcess.waitUntilExit()
        return String(data: processOutput, encoding: .utf8)!
    }

    func splitLines(_ text: String) -> [String] {
        var items = [String]()
        // We use this instead of split(whereSeparator:) or components(separatedBy:)
        // because we need to match the behavior of Python's splitlines()
        text.enumerateLines { line, stop in items.append(line) }
        return items
    }

}
