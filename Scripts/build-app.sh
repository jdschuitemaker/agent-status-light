#!/bin/zsh
set -euo pipefail
script_dir="${0:A:h}"
project_dir="${script_dir:h}"
output_dir="${project_dir}/dist/Agent Status Light.app"

swift build -c release --package-path "$project_dir"
mkdir -p "$output_dir/Contents/MacOS" "$output_dir/Contents/Resources"
cp "$project_dir/.build/release/AgentStatusLight" "$output_dir/Contents/MacOS/AgentStatusLight"
cp "$project_dir/Resources/Info.plist" "$output_dir/Contents/Info.plist"
codesign --force --sign - "$output_dir"
print "Built: $output_dir"
