#!/usr/bin/env python3

import shlex
import sys
import os
import re
import argparse
import logging
import textwrap
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description='Convert the Swift Language book to PDF using pandoc')
    parser.add_argument('book_path', type=Path, help='Path to directory containing the book source code (working copy of https://github.com/swiftlang/swift-book)')
    parser.add_argument('--pandoc-path', type=Path, help='Path to pandoc executable')
    parser.add_argument('--output-path-pdf', type=Path, default='The-Swift-Programming-Language.pdf', help='PDF output path')
    parser.add_argument('--output-path-epub', type=Path, default='The-Swift-Programming-Language.epub', help='ePUB output path')
    parser.add_argument('--debug-latex', action='store_true', help='Dump the latex intermediate code instead of the final PDF')

    args = parser.parse_args()

    generate_output(args.book_path.expanduser(), args.pandoc_path.expanduser(), args.output_path_pdf.expanduser(), args.output_path_epub.expanduser(), args.debug_latex)


def generate_output(book_path, pandoc_path, output_path_pdf, output_path_epub, debug_latex):
    combined_markdown_path = combine_and_rewrite_markdown_files(book_path, pandoc_path)

    common_options = [
        '--from', 'markdown',
        os.fspath(combined_markdown_path),
        '--resource-path', os.fspath(book_path / 'TSPL.docc/Assets'),
        '--highlight-style', 'tspl-code-highlight.theme',
        '--standalone',
        '--lua-filter', 'rewrite-retina-image-references.lua',
    ]

    option_sets = []

    if debug_latex:
        option_sets.append(common_options + ['--to', 'latex', '--output', os.fspath(output_path_pdf.with_suffix('.tex'))])
    else:
        epub_options = [
            '--to', 'epub3',
            '--toc',
            '--split-level=2',
            '--epub-embed-font=/Library/Fonts/SF-Pro-Text-Regular.otf',
            '--epub-embed-font=/Library/Fonts/SF-Pro-Text-RegularItalic.otf',
            '--epub-embed-font=/Library/Fonts/SF-Pro-Text-Bold.otf',
            '--epub-embed-font=/Library/Fonts/SF-Pro-Text-BoldItalic.otf',
            '--epub-embed-font=/Library/Fonts/SF-Mono.ttc',
            '--css', 'tspl-epub.css',
            '--output', os.fspath(output_path_epub)
        ]
        option_sets.append(common_options + epub_options)

        pdf_options = [
            '--to', 'pdf',
            '--pdf-engine', 'lualatex',
            '--variable', 'linkcolor=[HTML]{de5d43}',
            '--template', 'tspl-pandoc-template',
            '--output', os.fspath(output_path_pdf),
        ]
        option_sets.append(common_options + pdf_options)

    for options in option_sets:
        cmd = [os.fspath(pandoc_path)] + options
        if subprocess.run(cmd, text=True).returncode:
            print(f'pandoc command execution failure:\n{shlex.join(cmd)}')
        else:
            output_path = next(x for i, x in enumerate(options) if i and options[i - 1] == '--output')
            print(f'Output written to {output_path}')


def combine_and_rewrite_markdown_files(book_path, pandoc_path):
    # Preprocess the main md file that pulls in all the per-chapter files and shift up its headings by
    # two levels. We want to get the few headings ("Language Guide", "Language Reference" etc.) that introduce
    # related sets of chapters up to level 1, so that they become the toplevel heading structure visible in
    # the table of contents.
    cmd = [os.fspath(pandoc_path), '--from', 'markdown', '--to', 'markdown', os.fspath(book_path / 'TSPL.docc/The-Swift-Programming-Language.md'), '--shift-heading-level-by=-2']
    result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    main_file_markdown_text = result.stdout

    # This preprocessing step of the main file performs the inclusion of all referenced
    # per-chapter files, resulting in one large markdown file that contains all content,
    # which we then run through pandoc.
    combined_book_markdown_lines = preprocess_main_file_markdown(book_path, pandoc_path, main_file_markdown_text)
    combined_markdown_path = Path('swiftbook-combined.md')
    combined_markdown_path.write_text('\n'.join(combined_book_markdown_lines))
    return combined_markdown_path


def preprocess_main_file_markdown(book_path, pandoc_path, main_markdown_file_text):
    # The DocC inclusion directives as well as cross-references refer to the per-chapter
    # files with the "stem", the filename without extension. We need to be able to map
    # from those stems to the full file paths and also to the human-readable document
    # titles for each file, so build a mapping here that we can then pass around.
    paths_and_titles_mapping = book_markdown_file_stems_to_paths_and_titles_mapping(book_path)

    # Converting the entire book takes a while, this lets us pick a chapter subset
    # when we need to iterate more quickly on a specific conversion problem.
    debug_chapters_subset = None
    # debug_chapters_subset = set(['Closures', 'Enumerations', 'Properties'])

    # combined_book_markdown_lines is where we accumulate all lines of the big combined
    # markdown file. We start it out with a YAML header section that lets us control
    # many details of the pandoc conversion.
    combined_book_markdown_lines = markdown_header_lines(book_path)

    # Because of the heading level shifting we performed earlier on the main file,
    # there will be some paragraphs that were formerly headings that we no longer need.
    # This state machine skips over that content until we reach the first heading and then
    # starts processing the DocC <doc:... include directives.
    state = 'waiting_for_first_heading'
    for line in main_markdown_file_text.splitlines(keepends=False):
        if state == 'waiting_for_first_heading':
            if line.startswith('# '):
                state = 'processing_document_includes'
                combined_book_markdown_lines.append(line)                
        elif state == 'processing_document_includes':
            if match := re.match(r'^-\s*`<doc:(\w+)>`.*$', line):
                # We found a chapter include directive, process and add
                # the lines of the referenced file at this point
                markdown_file_to_include_stem = match.group(1)
                if not debug_chapters_subset or markdown_file_to_include_stem in debug_chapters_subset:
                    combined_book_markdown_lines.extend(lines_for_included_document(markdown_file_to_include_stem, pandoc_path, paths_and_titles_mapping, book_path))
                continue

            # The line is something else, add it to the combined output unchanged
            if line.startswith('# '):
                combined_book_markdown_lines.append(r'\newpage{}')
            combined_book_markdown_lines.append(line)

    return combined_book_markdown_lines


def book_markdown_file_stems_to_paths_and_titles_mapping(book_path):
    return dict([(path.stem, (path, title_from_first_heading_in_markdown_file(path))) for path in book_path.rglob('*.md')])


def lines_for_included_document(markdown_file_stem, pandoc_path, paths_and_titles_mapping, book_path):
    markdown_file_path = paths_and_titles_mapping[markdown_file_stem][0]
    text = markdown_file_path.read_text()
    # TODO: remove this regex processing after non-well-formed HTML comments
    # (containing double dashes) are fixed in the upstream book sources
    text = re.sub(r'<!--.+?-->', '', text, flags=re.DOTALL)
    lines = rewrite_docc_markdown_chapter_file_for_pandoc(text.splitlines(keepends=False), paths_and_titles_mapping, book_path)
    # This enforces a page break after a chapter for PDF output and 
    # it doesn't seem to negatively impact the ePUB output.
    return [r'\newpage{}'] + lines + ['']


def rewrite_docc_markdown_chapter_file_for_pandoc(markdown_lines, paths_and_titles_mapping, book_path):
    out = []

    state = 'start'
    pushback = None
    while markdown_lines or pushback:
        if pushback:
            line = pushback
            pushback = None
        else:
            line = rewrite_docc_markdown_line_for_pandoc(markdown_lines.pop(0), paths_and_titles_mapping, book_path)

        match state:
            case 'start':
                if match := re.match(r'- term (.+):', line):
                    out.append(match.group(1))
                    state = 'start_definition_list'
                else:
                    out.append(line)
            case 'start_definition_list':
                pushback = line
                out.append('')
                state = 'reading_definition_list_definition_first_line'
            case 'reading_definition_list_definition_first_line':
                out.append(f':    {line.lstrip()}')
                state = 'reading_definition_list_definition'
            case 'reading_definition_list_definition':
                if not line:
                    out.append('')
                elif re.match(r'\s+', line) or not line:
                    out.append(f'    {line.lstrip()}')
                else:
                    state = 'start'
                    pushback = line

    return out


# This function performs all rewriting that can be done within a single line.
# More complex multi-line rewriting should happen in the state machine that this is called from.
def rewrite_docc_markdown_line_for_pandoc(line, paths_and_titles_mapping, book_path):
    line = rewrite_docc_markdown_line_for_pandoc_internal_references(line, paths_and_titles_mapping)
    line = rewrite_docc_markdown_line_for_pandoc_optionality_marker(line)
    line = rewrite_docc_markdown_line_for_pandoc_image_reference(line, book_path)
    line = rewrite_docc_markdown_line_for_pandoc_heading_level_shift(line)
    return line


def rewrite_docc_markdown_line_for_pandoc_heading_level_shift(line):
    if match := re.match(r'(#+ .+)', line):
        # We need to shift down the heading levels for each included
        # per-chapter markdown file by one level so they line up with
        # the headings in the main file.
        return '#' + match.group(1)
    return line


def rewrite_docc_markdown_line_for_pandoc_image_reference(line, book_path):    
    if not (match := re.match(r'!\[([^\]]*)\]\(([\w-]+)\)', line)):
        return line

    caption, image_filename_prefix = match.groups()
    image_filename = Path(image_filename_prefix + '@2x.png')
    image_path = book_path / 'TSPL.docc/Assets' / image_filename
    assert image_path.exists()
    output = subprocess.check_output(['file', os.fspath(image_path)], text=True)
    match = re.search(r'PNG image data, (\d+) x \d+', output)
    assert match
    width = match.group(1)
    # Dividing the width by two and then dividing that by about 760
    # gives us the scale factor that will match the image presentation
    # in the online web version.
    scale_percentage = int(float(width) / 2 / 7.6)
    return f'![{caption}]({image_filename}){{ width={scale_percentage}% }}'


def rewrite_docc_markdown_line_for_pandoc_internal_references(line, paths_and_titles_mapping):
    def pandoc_markdown_reference_for_docc_reference_match(match):
        text = match.group(1)
        if '#' in text:
            _, section = text.split('#')
            human_readable_label = section.replace('-', ' ')
        else:
            human_readable_label = paths_and_titles_mapping[text][1]
        identifier = human_readable_label.lower().replace(' ', '-')
        return f'[{human_readable_label}](#{identifier})'

    line = re.sub(r'<doc:([\w#-]+)>', pandoc_markdown_reference_for_docc_reference_match, line)

    return line


def rewrite_docc_markdown_line_for_pandoc_optionality_marker(line):
    # This fixes the markup used for ? optionality
    # markers used in grammar blocks
    return re.sub(r'(\*{1,2})_\?_', r'?\1', line)


def markdown_header_lines(book_path):
    first_level_1_heading = title_from_first_heading_in_markdown_file(book_path / 'TSPL.docc/The-Swift-Programming-Language.md')
    git_tag_or_ref = git_tag_or_ref_for_working_copy_path(book_path)
    timestamp = subprocess.check_output(['git', '-C', os.fspath(book_path), 'for-each-ref', '--format', '%(taggerdate:short)', f'refs/tags/{git_tag_or_ref}'], text=True).strip()
    if not timestamp:
        timestamp = subprocess.check_output(['git', '-C', os.fspath(book_path), 'show', '--no-patch', '--pretty=format:%cs', git_tag_or_ref], text=True).strip()
    assert len(timestamp)

    return textwrap.dedent(f'''
        ---
        title: {first_level_1_heading}
        date: "{timestamp}"
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
    ''').splitlines(keepends=False)


def title_from_first_heading_in_markdown_file(path):
    with path.open() as f:
        return next((line[2:] for line in f if line.startswith('# ')), None)


def git_tag_or_ref_for_working_copy_path(working_copy_path):
    output = subprocess.check_output(['git', '-C', os.fspath(working_copy_path), 'tag', '--points-at', 'HEAD'], text=True)
    tags = [l for l in output.splitlines(keepends=False) if l]
    if tags:
        return tags[0]

    output = subprocess.check_output(['git', '-C', os.fspath(working_copy_path), 'symbolic-ref', '--short', 'HEAD'], text=True)
    refs = [l for l in output.splitlines(keepends=False) if l]
    return refs[0]


if __name__ == "__main__":
    sys.exit(main())
