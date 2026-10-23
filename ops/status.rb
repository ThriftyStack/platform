#!/usr/bin/env ruby
# Read-only ceremony status. Exit non-zero when the next stage is blocked.
require 'yaml'
require 'json'
require 'open3'
ROOT = File.expand_path('..', __dir__)
STAGES = %w[vault pki certificates istio qualification enrollment].freeze
require_relative 'cluster'

def try_run(*args)
  args = [args[0], '--context', CONTEXT, *args.drop(1)] if %w[kubectl istioctl].include?(args[0])
  out, _, status = Open3.capture3(*args)
  status.success? ? out : nil
end

def try_argo(*args)
  return try_run(*args) if CLUSTER['role'] == 'management'
  context = ENV['ARGO_CONTEXT']
  return nil if context.to_s.empty?
  config = YAML.safe_load(File.read("#{ROOT}/clusters/management/cluster.yaml"))['cluster']
  out, _, status = Open3.capture3('kubectl', '--context', context, 'config', 'view', '--minify', '-o', 'jsonpath={.clusters[0].cluster.server}')
  return nil unless status.success? && out.strip == config.fetch('operatorServer')
  out, _, status = Open3.capture3(args[0], '--context', context, *args.drop(1))
  status.success? ? out : nil
end

def app_state(name)
  raw = try_argo('kubectl', '-n', 'argocd', 'get', 'application', application_name(name), '-o', 'json')
  return { sync: 'Missing', health: 'Missing' } unless raw
  o = JSON.parse(raw)
  { sync: o.dig('status', 'sync', 'status') || 'Unknown', health: o.dig('status', 'health', 'status') || 'Unknown' }
end

def healthy?(name)
  s = app_state(name)
  s[:sync] == 'Synced' && s[:health] == 'Healthy'
end

def line(label, value)
  puts format('%-28s %s', label, value)
end

values = YAML.safe_load(File.read("#{ROOT}/clusters/#{CLUSTER_ID}/values.yaml"))
stages = values.fetch('stages')
applicable = STAGES.reject { |s| CLUSTER['role'] != 'management' && %w[vault pki].include?(s) }

puts "Cluster #{CLUSTER_ID} (#{CLUSTER['role']}) context=#{CONTEXT}"
puts 'Stages:'
applicable.each { |s| line(s, stages[s] ? 'enabled' : 'pending') }

apps = case CLUSTER['role']
       when 'management'
         %w[longhorn netbird crossplane vault-provider vault vault-pki cert-manager mesh-prerequisites vault-issuer cert-manager-istio-csr istio-base istiod mesh-qualification mesh-enrollment controlplane-authentik]
       else
         %w[cert-manager mesh-prerequisites vault-issuer cert-manager-istio-csr istio-base istiod mesh-qualification mesh-enrollment]
       end
puts 'Argo Applications:'
apps.each do |name|
  state = app_state(name)
  line(application_name(name), "#{state[:sync]}/#{state[:health]}")
end

if CLUSTER['role'] == 'management'
  puts 'Vault:'
  vault_ns = try_run('kubectl', 'get', 'ns', 'vault', '-o', 'name')
  if vault_ns
    3.times do |i|
      raw = try_run('kubectl', '-n', 'vault', 'exec', "vault-#{i}", '--', 'vault', 'status', '-format=json')
      if raw
        status = JSON.parse(raw)
        line("vault-#{i}", "initialized=#{status['initialized']} sealed=#{status['sealed']} storage=#{status['storage_type']}")
      else
        line("vault-#{i}", 'unreachable')
      end
    end
  else
    line('namespace', 'absent')
  end

  puts 'PKI:'
  generation = CLUSTER.fetch('issuerGeneration')
  [
    ['secretbackendrootcerts.pki.vault.upbound.io', 'workload-root'],
    ['secretbackendintermediatecertrequests.pki.vault.upbound.io', generation],
    ['secretbackendintermediatesetsigneds.pki.vault.upbound.io', generation]
  ].each do |kind, name|
    raw = try_run('kubectl', 'get', kind, name, '-o', 'json')
    if raw
      ready = JSON.parse(raw).fetch('status', {}).fetch('conditions', []).any? { |c| c['type'] == 'Ready' && c['status'] == 'True' }
      line(name, ready ? 'Ready' : 'NotReady')
    else
      line(name, 'absent')
    end
  end
end

puts 'Mesh:'
issuer = try_run('kubectl', '-n', 'istio-system', 'get', 'issuer', 'vault-istio', '-o', 'json')
line('issuer/vault-istio', issuer && JSON.parse(issuer).dig('status', 'conditions')&.any? { |c| c['type'] == 'Ready' && c['status'] == 'True' } ? 'Ready' : (issuer ? 'NotReady' : 'absent'))
cert = try_run('kubectl', '-n', 'istio-system', 'get', 'certificate', 'istiod', '-o', 'json')
line('certificate/istiod', cert && JSON.parse(cert).dig('status', 'conditions')&.any? { |c| c['type'] == 'Ready' && c['status'] == 'True' } ? 'Ready' : (cert ? 'NotReady' : 'absent'))
pods = try_run('kubectl', '-n', 'mesh-test', 'get', 'pods', '-o', 'json')
if pods
  items = JSON.parse(pods).fetch('items', [])
  line('mesh-test pods', items.empty? ? 'none' : items.map { |p| "#{p.dig('metadata', 'name')}=#{p.dig('status', 'phase')}" }.join(', '))
else
  line('mesh-test pods', 'namespace absent')
end
evidence = "#{ROOT}/.evidence/#{CLUSTER_ID}/renewal.json"
line('renewal evidence', File.exist?(evidence) ? evidence.sub("#{ROOT}/", '') : 'absent')

next_stage = applicable.find { |s| !stages[s] }
blockers = []
if next_stage.nil?
  puts 'Next: ceremony stages complete; revoke bootstrap root when break-glass recovery is ready (see bootstrap/VAULT-PKI.md).'
  exit 0
end

index = STAGES.index(next_stage)
STAGES.take(index).reject { |s| CLUSTER['role'] != 'management' && %w[vault pki].include?(s) }.each do |s|
  blockers << "enable #{s} first" unless stages[s]
end

case next_stage
when 'vault'
  %w[longhorn crossplane vault-provider].each { |a| blockers << "#{a} not Synced/Healthy" unless healthy?(a) } if CLUSTER['role'] == 'management'
  %w[vault-tls vault-seal vault-kms].each do |secret|
    blockers << "missing secret/#{secret}" unless try_run('kubectl', '-n', 'vault', 'get', 'secret', secret, '-o', 'name')
  end
when 'pki'
  blockers << 'vault Application not Synced/Healthy' unless healthy?('vault')
  3.times do |i|
    raw = try_run('kubectl', '-n', 'vault', 'exec', "vault-#{i}", '--', 'vault', 'status', '-format=json')
    status = raw && JSON.parse(raw)
    blockers << "vault-#{i} not initialized/unsealed/raft" unless status && status['initialized'] && !status['sealed'] && status['storage_type'] == 'raft'
  end
  blockers << 'missing vault-bootstrap-ca ConfigMap (run bootstrap-auth)' unless try_run('kubectl', '-n', 'crossplane-system', 'get', 'configmap', 'vault-bootstrap-ca', '-o', 'name')
when 'certificates'
  blockers << 'vault-pki not Synced/Healthy' unless healthy?('vault-pki')
  blockers << 'root trust template missing (pki-trust)' unless File.exist?("#{ROOT}/infrastructure/configuration/mesh-prerequisites/templates/root-ca.yaml")
when 'istio'
  %w[cert-manager vault-issuer mesh-prerequisites].each { |a| blockers << "#{a} not Synced/Healthy" unless healthy?(a) }
  raw = try_run('kubectl', '-n', 'istio-system', 'get', 'issuer', 'vault-istio', '-o', 'json')
  ready = raw && JSON.parse(raw).dig('status', 'conditions')&.any? { |c| c['type'] == 'Ready' && c['status'] == 'True' }
  blockers << 'issuer/vault-istio not Ready' unless ready
when 'qualification'
  %w[cert-manager-istio-csr istiod istio-base].each { |a| blockers << "#{a} not Synced/Healthy" unless healthy?(a) }
  raw = try_run('kubectl', '-n', 'istio-system', 'get', 'certificate', 'istiod', '-o', 'json')
  ready = raw && JSON.parse(raw).dig('status', 'conditions')&.any? { |c| c['type'] == 'Ready' && c['status'] == 'True' }
  blockers << 'certificate/istiod not Ready' unless ready
when 'enrollment'
  blockers << 'mesh-qualification not Synced/Healthy' unless healthy?('mesh-qualification')
  blockers << 'renewal evidence missing (make verify-mesh-renewal)' unless File.exist?(evidence)
end

if blockers.empty?
  puts "Next: make promote-pr STAGE=#{next_stage}"
  exit 0
end

puts "Next stage #{next_stage} blocked:"
blockers.each { |b| puts "  - #{b}" }
hint = case next_stage
       when 'vault' then 'Deliver vault secrets via bootstrap/vault/prepare.sh, then promote-pr STAGE=vault'
       when 'pki' then 'Finish vault init + bootstrap/vault/bootstrap-auth.sh, then promote-pr STAGE=pki'
       when 'certificates' then 'make pki-sign && make pki-trust, publish handoff, wait for vault-pki Healthy'
       when 'istio' then 'Wait for cert-manager / vault-issuer / mesh-prerequisites Ready'
       when 'qualification' then 'Wait for istio-csr and istiod Certificate Ready'
       when 'enrollment' then 'make verify-mesh-renewal, then promote-pr STAGE=enrollment'
       else 'See bootstrap/VAULT-PKI.md'
       end
puts "Hint: #{hint}"
exit 1
