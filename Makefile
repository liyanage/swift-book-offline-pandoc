#PRE_RELEASE_SUFFIX := Beta 1
ifdef PRE_RELEASE_SUFFIX
        PRE_RELEASE_SUFFIX_OPTION := --version-number-suffix "$(PRE_RELEASE_SUFFIX)"
        PRE_RELEASE_VERSION_ADDITION := " ($(PRE_RELEASE_SUFFIX))"
endif

VERSION := $(shell awk '/^\# The Swift Programming Language/ {print $$6; }' ~/git/swift-book/TSPL.docc/The-Swift-Programming-Language.md | tr -d '()')

.PHONY: cover

cover:
	swift run cover-generator --output "cover/cover-$(VERSION)"$(PRE_RELEASE_VERSION_ADDITION)".png" --version "Swift $(VERSION)"$(PRE_RELEASE_VERSION_ADDITION)" Edition"

book:
	swift run swift-book-offline "$(PRE_RELEASE_SUFFIX_OPTION)" --pandoc-path pandoc-3.4-arm64/bin/pandoc ~/git/swift-book 

