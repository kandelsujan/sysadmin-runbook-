#!/usr/bin/env ruby
# Two gates on the Puppetfile:
#
#   1. Every entry must be pinned (version, tag, or ref). An unpinned mod means
#      r10k can resolve different code on different compilers for the same
#      environment -- drift nobody can reproduce.
#
#   2. Pre-release tags (-rc, -beta, -alpha) are permitted ONLY on the reg
#      branch. reg is the validation tier; imp and vip pin final tags cut from
#      a module's main branch after the change proved out on reg. This encodes
#      the rollout policy in CI so it does not depend on reviewer memory.
#
# Branch pinning (branch:/ref: pointing at a branch name) is discouraged
# everywhere -- a branch moves under you; a tag does not -- but only hard-fails
# outside reg.

branch = ENV['CI_COMMIT_BRANCH'] || ENV['CI_MERGE_REQUEST_TARGET_BRANCH_NAME'] || ''
prerelease_ok = (branch == 'reg')

unpinned = []
prerelease = []

File.readlines('Puppetfile').each_with_index do |line, i|
  next unless line =~ /^\s*mod\s+/
  next if line =~ /(:latest|['"]\d|:tag|:ref|:commit|:branch)/
  unpinned << "line #{i + 1}: #{line.strip}" unless line.strip.end_with?(',')
end

content = File.read('Puppetfile')
content.scan(/tag:\s*['"]([^'"]+)['"]/).flatten.each do |tag|
  prerelease << tag if tag =~ /-(rc|beta|alpha)\d*/i
end

failed = false

if unpinned.any?
  warn 'Unpinned Puppetfile entries:'
  unpinned.each { |e| warn "  #{e}" }
  failed = true
end

if prerelease.any? && !prerelease_ok
  warn "Pre-release tags are only permitted on the reg branch (this is '#{branch}'):"
  prerelease.each { |t| warn "  #{t}" }
  warn 'Cut a final tag from the module main branch after validation on reg.'
  failed = true
end

exit 1 if failed
msg = "Puppetfile: all entries pinned"
msg += ", #{prerelease.size} pre-release tag(s) (allowed on reg)" if prerelease.any?
puts msg
