#!/usr/bin/env ruby
# Live gates via promote.rb, then open a GitHub PR. Never merges, force-pushes, or syncs Argo.
require 'yaml'
require 'open3'
require 'time'
ROOT = File.expand_path('..', __dir__)
require_relative 'stages'
require_relative 'cluster'

stage = ARGV.fetch(0)
abort 'Unknown stage' unless Ceremony::PROMOTE_PR.include?(stage)
path = "#{ROOT}/clusters/#{CLUSTER_ID}/values.yaml"
relative = "clusters/#{CLUSTER_ID}/values.yaml"
before = File.read(path)
abort "#{stage} is already enabled" if YAML.safe_load(before).dig('stages', stage)

gate_env = ENV.to_hash.merge('THRIFTY_CLUSTER' => CLUSTER_ID)
gate_out, gate_err, gate_status = Open3.capture3(gate_env, 'ruby', "#{ROOT}/ops/promote.rb", stage)
$stdout.print gate_out
$stderr.print gate_err
abort 'Promotion gates failed; no PR opened' unless gate_status.success?
after = File.read(path)
abort 'promote.rb did not update values.yaml' if after == before

def git(*args)
  out, err, status = Open3.capture3('git', '-C', ROOT, *args)
  raise "git #{args[0]} failed (exit #{status.exitstatus})" unless status.success?
  out
end

utc = Time.now.utc.strftime('%Y%m%dT%H%M%SZ')
branch = "ceremony/#{CLUSTER_ID}/#{stage}-#{utc}"
git('checkout', '-b', branch)
git('add', '--', relative)
subject = "feat(ceremony): enable #{stage} on #{CLUSTER_ID}"
body = "Live gates passed for #{stage}; humans merge so Argo can reconcile from main."
git('commit', '-m', subject, '-m', body)
# Never --force.
git('push', '-u', 'origin', 'HEAD')

pr_body = <<~EOF
## Summary
- Enable stage `#{stage}` on cluster `#{CLUSTER_ID}` after live gates.
- Desired-state edit is limited to `#{relative}`.

## Live gates
```
#{gate_out.strip.empty? ? '(promote.rb completed with no stdout)' : gate_out.strip}
```

## Operator rules
- Human merge only — this change does not auto-merge.
- No force-push and no Argo sync API calls.
- Day-0 Vault prepare / init / bootstrap-auth stay in bootstrap (out of band).

## Runbook
See sibling bootstrap checklist: `bootstrap/VAULT-PKI.md`
EOF

title = "feat(ceremony): enable #{stage} on #{CLUSTER_ID}"
out, err, status = Open3.capture3('gh', 'pr', 'create', '--title', title, '--body', pr_body, chdir: ROOT)
$stdout.print out
$stderr.print err
abort 'gh pr create failed' unless status.success?
puts "Opened promote PR for #{stage}; merge manually when ready."
