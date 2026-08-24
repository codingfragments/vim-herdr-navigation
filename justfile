# vim-herdr-navigation — justfile
#
# Common dev workflows. `just` reads this file; install it from
# https://github.com/casey/just or `brew install just`.
#
#   just build        cargo build --release
#   just link         herdr plugin link .            (local dev checkout)
#   just unlink       herdr plugin unlink vim-herdr-navigation
#   just relink       unlink + link (after rebuilding)
#   just test         build + run the dry-run harness against the fake herdr
#   just replace-gh   unlink local, install the published GitHub version

plugin_id := "vim-herdr-navigation"
gh_repo   := "codingfragments/vim-herdr-navigation"
bin       := "target/release/navigate"

# default recipe
default: build

# Build the release binary
build:
    cargo build --release

# Link this local checkout as a herdr plugin
link: build
    herdr plugin link .

# Unlink the local plugin (tolerant: no error if not linked)
unlink:
    -herdr plugin unlink {{plugin_id}}

# Rebuild + relink (unlink then link)
relink: unlink link

# Run the dry-run test harness against the fake herdr + fake socket
test: build
    ./test/dry-run.sh

# Replace the local dev link with the published GitHub version
replace-gh: unlink
    herdr plugin install  {{gh_repo}} -y
