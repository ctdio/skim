#!/usr/bin/env bash
#
# Update Tree-sitter syntax highlighting queries
# Downloads the latest highlights.scm files from official tree-sitter repositories

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
QUERIES_DIR="$PROJECT_ROOT/src/queries"

# Create queries directory if it doesn't exist
mkdir -p "$QUERIES_DIR"

echo "Updating Tree-sitter syntax highlighting queries..."
echo ""

# Function to download a query file
download_query() {
    local lang="$1"
    local url="$2"
    local output="$QUERIES_DIR/${lang}.scm"

    echo "Downloading $lang..."
    if curl -sf "$url" -o "$output"; then
        echo "✓ $lang ($(wc -l < "$output" | tr -d ' ') lines)"
    else
        echo "✗ Failed to download $lang"
        exit 1
    fi
}

# Download programming languages
download_query "javascript" "https://raw.githubusercontent.com/tree-sitter/tree-sitter-javascript/master/queries/highlights.scm"
download_query "typescript" "https://raw.githubusercontent.com/tree-sitter/tree-sitter-typescript/master/queries/highlights.scm"
download_query "python" "https://raw.githubusercontent.com/tree-sitter/tree-sitter-python/master/queries/highlights.scm"
download_query "rust" "https://raw.githubusercontent.com/tree-sitter/tree-sitter-rust/master/queries/highlights.scm"
download_query "go" "https://raw.githubusercontent.com/tree-sitter/tree-sitter-go/master/queries/highlights.scm"
download_query "zig" "https://raw.githubusercontent.com/tree-sitter-grammars/tree-sitter-zig/master/queries/highlights.scm"
download_query "c" "https://raw.githubusercontent.com/tree-sitter/tree-sitter-c/master/queries/highlights.scm"
download_query "cpp" "https://raw.githubusercontent.com/tree-sitter/tree-sitter-cpp/master/queries/highlights.scm"

# Download common file formats
download_query "json" "https://raw.githubusercontent.com/tree-sitter/tree-sitter-json/master/queries/highlights.scm"
download_query "yaml" "https://raw.githubusercontent.com/tree-sitter-grammars/tree-sitter-yaml/master/queries/highlights.scm"
download_query "toml" "https://raw.githubusercontent.com/tree-sitter-grammars/tree-sitter-toml/master/queries/highlights.scm"
download_query "markdown" "https://raw.githubusercontent.com/tree-sitter-grammars/tree-sitter-markdown/master/tree-sitter-markdown/queries/highlights.scm"
download_query "html" "https://raw.githubusercontent.com/tree-sitter/tree-sitter-html/master/queries/highlights.scm"
download_query "css" "https://raw.githubusercontent.com/tree-sitter/tree-sitter-css/master/queries/highlights.scm"
download_query "bash" "https://raw.githubusercontent.com/tree-sitter/tree-sitter-bash/master/queries/highlights.scm"

echo ""
echo "All syntax highlighting queries updated successfully!"
echo ""
echo "Query files location: $QUERIES_DIR"
echo ""
echo "Rebuild with: zig build"
