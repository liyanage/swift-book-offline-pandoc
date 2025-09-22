

book: .build/debug/swift-book-offline
	.build/debug/swift-book-offline --pandoc-path pandoc-3.4-arm64/bin/pandoc ~/git/swift-book

.build/debug/swift-book-offline:
	swift build

