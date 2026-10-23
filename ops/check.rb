#!/usr/bin/env ruby
# Offline contracts and exact artifact rendering; no cluster calls.
require 'yaml'
require 'json'
require 'digest'
require 'open3'
require 'tempfile'
ROOT = File.expand_path('..', __dir__)
CACHE = ENV.fetch('CHART_CACHE')
HELM = ENV.fetch('HELM', 'helm')
CHART = "#{ROOT}/charts/cluster-apps"
def cluster_profile(id)
  ['-f', "#{ROOT}/clusters/#{id}/values.yaml", '-f', "#{ROOT}/clusters/#{id}/cluster.yaml"]
end
def check(value, message)
  raise message unless value
end
def documents(text)
  text.split(/^---\s*$/).reject { |s| s.strip.empty? }.map { |s| YAML.safe_load(s, permitted_classes: [Time], aliases: true) }.compact
end
def render(*args)
  output, error, status = Open3.capture3(*args)
  raise error unless status.success?
  documents(output)
end
def validate(value, schema, location)
  return if value.nil?
  type = schema['type']
  valid = case type
          when 'object' then value.is_a?(Hash)
          when 'array' then value.is_a?(Array)
          when 'string' then value.is_a?(String)
          when 'integer' then value.is_a?(Integer)
          when 'number' then value.is_a?(Numeric)
          when 'boolean' then [true, false].include?(value)
          else true
          end
  check(valid, "#{location}: expected #{type}")
  check(schema['enum'].include?(value), "#{location}: invalid enum") if schema['enum']
  if value.is_a?(Hash) && schema['properties']
    (schema['required'] || []).each { |key| check(value.key?(key), "#{location}: missing #{key}") }
    value.each do |key, item|
      child = schema['properties'][key]
      check(child || schema['additionalProperties'] || schema['x-kubernetes-preserve-unknown-fields'], "#{location}: unknown field #{key}")
      validate(item, child, "#{location}.#{key}") if child
    end
  elsif value.is_a?(Array) && schema['items']
    value.each { |item| validate(item, schema['items'], location) }
  end
end
lock = JSON.parse(File.read("#{ROOT}/dependencies.lock.json"))
(lock['charts'] + lock['vaultProvider']['schemas'] + lock.fetch('validationCharts', [])).each do |artifact|
  file = "#{CACHE}/#{artifact['archive'] || artifact['file']}"
  check(Digest::SHA256.file(file).hexdigest == artifact['sha256'], "Locked artifact mismatch #{file}")
end
schemas = lock['vaultProvider']['schemas'].map { |s| YAML.safe_load(File.read("#{CACHE}/#{s['file']}"), aliases: true) }
crd_scope = schemas.to_h { |s| [[s.dig('spec', 'group'), s.dig('spec', 'names', 'kind')], s.dig('spec', 'scope')] }
stage_flags = %w[vault pki certificates istio qualification enrollment].flat_map { |s| ['--set', "stages.#{s}=true"] }
management_docs = render(HELM, 'template', 'management', CHART, *cluster_profile('management'), *stage_flags)
apps = management_docs.select { |o| o['kind']=='Application' }
by_name = apps.to_h { |a| [a['metadata']['name'], a] }
order = %w[longhorn netbird crossplane vault-provider vault vault-pki cert-manager mesh-prerequisites vault-issuer cert-manager-istio-csr istio-base istiod mesh-qualification mesh-enrollment controlplane-authentik]
waves = order.map { |name| by_name.fetch(name).dig('metadata', 'annotations', 'argocd.argoproj.io/sync-wave').to_i }
check(waves.each_cons(2).all? { |a,b| a < b }, 'Dependency waves must follow deployment order')
authentik = by_name.fetch('controlplane-authentik')
authentik_source = authentik.dig('spec','source')
check(authentik_source['repoURL'] == 'https://github.com/ThriftyStack/controlplane.git', 'Authentik root must track the controlplane repository')
check(authentik_source['targetRevision'] == 'main', 'Authentik root tracks main')
check(authentik_source['path'] == 'deploy/authentik', 'Authentik root path')
check(authentik_source['directory'] == {'recurse' => false}, 'Authentik root must not recurse')
check(authentik_source['helm'].nil?, 'Authentik root is a directory, not a Helm chart')
check(authentik.dig('spec','project') == 'management', 'Authentik root uses the management project')
check(authentik.dig('spec','destination') == {'server' => 'https://kubernetes.default.svc', 'namespace' => 'crossplane-system'}, 'Authentik root destination')
check(authentik.dig('spec','syncPolicy','automated') == {'prune' => false, 'selfHeal' => true}, 'Authentik root self-heals and does not prune')
check(authentik.dig('spec','syncPolicy','syncOptions').include?('ServerSideApply=true'), 'Authentik root uses server-side apply')
check(authentik.dig('spec','syncPolicy','syncOptions').include?('SkipDryRunOnMissingResource=true'), 'Authentik root must apply the OpenTofu provider before its CRDs exist')
check(authentik.dig('metadata','annotations','argocd.argoproj.io/sync-wave').to_i > by_name.fetch('crossplane').dig('metadata','annotations','argocd.argoproj.io/sync-wave').to_i, 'Authentik root syncs after Crossplane')
project = management_docs.find { |o| o['kind']=='AppProject' && o.dig('metadata','name')=='management' }
check(project, 'Management AppProject must be rendered')
check(project.dig('spec','sourceRepos') == ['https://github.com/ThriftyStack/platform.git', 'https://github.com/ThriftyStack/controlplane.git'], 'Management project sources platform and controlplane')
check(project.dig('spec','clusterResourceWhitelist').none? { |r| r.values.include?('*') }, 'No wildcard management cluster privileges')
check(project.dig('spec','destinations').none? { |d| d['namespace'] == 'kube-system' }, 'Management project must not permit kube-system')
check(project.dig('spec','destinations').any? { |d| d == {'server' => 'https://kubernetes.default.svc', 'namespace' => 'crossplane-system'} }, 'Management project permits crossplane-system')
check(project.dig('metadata','annotations','argocd.argoproj.io/sync-wave').to_i < waves.first, 'Management project syncs before platform Applications')
app_namespaces = apps.map { |a| a.dig('spec','destination','namespace') }.uniq
project_namespaces = project.dig('spec','destinations').map { |d| d['namespace'] }
check(app_namespaces.all? { |ns| project_namespaces.include?(ns) }, 'Management project must allow every Application destination')
allow = project.dig('spec','clusterResourceWhitelist').map { |r| [r['group'], r['kind']] }
check(allow.include?(['opentofu.upbound.io', 'ProviderConfig']), 'Authentik ProviderConfig is cluster-scoped')
check(allow.include?(['pkg.crossplane.io', 'Provider']), 'Provider packages are cluster-scoped')
check(allow.include?(['pkg.crossplane.io', 'DeploymentRuntimeConfig']), 'Provider runtimes are cluster-scoped')
def ignores?(app, group, kind)
  (app.dig('spec', 'ignoreDifferences') || []).any? { |d| d['group'] == group && d['kind'] == kind }
end
check(ignores?(by_name.fetch('vault-pki'), 'vault.upbound.io', 'ProviderConfig'), 'vault-pki must ignore ProviderConfig header drift')
check(ignores?(by_name.fetch('istio-base'), 'admissionregistration.k8s.io', 'ValidatingWebhookConfiguration'), 'istio-base must ignore validating webhook drift')
check(ignores?(by_name.fetch('istiod'), 'admissionregistration.k8s.io', 'ValidatingWebhookConfiguration'), 'istiod must ignore validating webhook drift')
check(ignores?(by_name.fetch('istiod'), 'admissionregistration.k8s.io', 'MutatingWebhookConfiguration'), 'istiod must ignore mutating webhook drift')
Dir["#{ROOT}/clusters/*/overrides/**/*.yaml"].each do |path|
  text = File.read(path)
  check(!text.match?(/\A---\s*\{\}\s*\z/), "#{path}: reject invalid document form --- {}")
  begin
    doc = YAML.safe_load(text)
  rescue Psych::SyntaxError => e
    raise "#{path}: invalid override YAML (#{e.message})"
  end
  check(doc.is_a?(Hash), "#{path}: override must be a YAML mapping for Helm values")
end
rendered = {}
apps.each do |app|
  check(!app.dig('metadata','finalizers'), 'No cascading application deletion')
  check(app.dig('spec','syncPolicy','automated','prune') == false, 'No automated infrastructure pruning')
  source = app.dig('spec','source')
  if source['directory']
    check(app.dig('metadata','name') == 'controlplane-authentik', 'Only the Authentik root may use a directory source')
    next
  end
  check(source['path'].start_with?('infrastructure/'), 'Platform services must remain separate from workload application charts')
  chart = "#{ROOT}/#{source['path']}"
  values = source.dig('helm','valueFiles').flat_map { |f| ['-f',File.expand_path(f, chart)] }
  rendered[app['metadata']['name']] = render(HELM, 'template', source.dig('helm','releaseName'), chart,
    '--namespace',app.dig('spec','destination','namespace'),'--kube-version','1.36.5','--include-crds',
    *(source.dig('helm','skipTests') ? ['--skip-tests'] : []),*values)
  dependency = YAML.safe_load(File.read("#{chart}/Chart.yaml"))['dependencies']
  if dependency
    artifact = lock['charts'].find { |l| l['chart']==dependency[0]['name'] && l['version']==dependency[0]['version'] }
    check(artifact, 'Every dependency must have an exact artifact pin')
    check(Digest::SHA256.file("#{chart}/charts/#{artifact['archive']}").hexdigest==artifact['sha256'], 'Vendored dependency must match SHA256 lock')
    chart_lock = YAML.safe_load(File.read("#{chart}/Chart.lock"),permitted_classes:[Time])
    check(chart_lock['dependencies'][0]['version']==dependency[0]['version'], 'Helm lock version mismatch')
    canonical = dependency.map { |d| %w[name version repository].to_h { |k| [k,d.fetch(k)] } }
    expected = 'sha256:'+Digest::SHA256.hexdigest(JSON.generate([canonical,chart_lock['dependencies']]))
    check(chart_lock['digest']==expected, 'Helm dependency lock digest mismatch')
  end
end
cluster_groups = {
  'Namespace' => '',
  'CustomResourceDefinition' => 'apiextensions.k8s.io',
  'ClusterRole' => 'rbac.authorization.k8s.io',
  'ClusterRoleBinding' => 'rbac.authorization.k8s.io',
  'MutatingWebhookConfiguration' => 'admissionregistration.k8s.io',
  'ValidatingWebhookConfiguration' => 'admissionregistration.k8s.io',
  'ValidatingAdmissionPolicy' => 'admissionregistration.k8s.io',
  'ValidatingAdmissionPolicyBinding' => 'admissionregistration.k8s.io',
  'PriorityClass' => 'scheduling.k8s.io',
  'Provider' => 'pkg.crossplane.io',
  'DeploymentRuntimeConfig' => 'pkg.crossplane.io'
}
rendered.each_value do |objects|
  objects.each do |object|
    group = object['apiVersion'].to_s.include?('/') ? object['apiVersion'].split('/')[0] : ''
    kind = object['kind']
    if cluster_groups.key?(kind)
      check(cluster_groups[kind] == group, "Unexpected API group for #{kind}")
      check(allow.include?([group, kind]), "Management project must allow #{group}/#{kind}")
    elsif crd_scope[[group, kind]] == 'Cluster'
      check(allow.include?([group, kind]), "Management project must allow #{group}/#{kind}")
    end
  end
end
def configuration(name)
  render(HELM,'template',name,"#{ROOT}/infrastructure/configuration/#{name}")
end
Dir["#{ROOT}/infrastructure/configuration/*"].each do |directory|
  objects = configuration(File.basename(directory))
  objects.select { |o| o['apiVersion'].include?('vault.upbound.io') }.each do |object|
    crd = schemas.find { |s| s.dig('spec','group') == object['apiVersion'].split('/')[0] && s.dig('spec','names','kind') == object['kind'] }
    check(crd, "Missing official provider schema for #{object['kind']}")
    version = crd['spec']['versions'].find { |v| v['name'] == object['apiVersion'].split('/')[1] }
    validate(object['spec'],version['schema']['openAPIV3Schema']['properties']['spec'],object['metadata']['name'])
    if object['kind'] != 'ProviderConfig'
      check(object['spec']['deletionPolicy']=='Orphan' && !object['spec']['managementPolicies'].include?('Delete'), 'Vault resources must resist deletion')
    end
    if object['kind'].match?(/RootCert|IntermediateCertRequest/)
      check(object.dig('spec','forProvider','type')=='internal', 'Never export CA keys')
      check(object.dig('spec','managementPolicies')==%w[Observe Create], 'Never update CA generation automatically')
    end
  end
end
vault = rendered.fetch('vault')
sts = vault.find { |o| o['kind']=='StatefulSet' }
check(sts.dig('spec','replicas')==3 && sts.dig('spec','updateStrategy','type')=='OnDelete', 'Vault must be Raft HA with controlled upgrades')
pod = sts.dig('spec','template','spec'); container = pod['containers'].find { |c| c['name']=='vault' }
check(pod.dig('affinity','podAntiAffinity','requiredDuringSchedulingIgnoredDuringExecution').length==1, 'Vault pod separation must be required')
check(container.dig('readinessProbe','httpGet','path')=='/v1/sys/health?standbyok=true', 'Never mark sealed/uninitialized Vault ready')
check(container['args'].join.include?('-config=/vault/userconfig/vault-seal/seal.hcl'), 'External GCP seal config must be loaded')
check(sts['spec']['volumeClaimTemplates'].all? { |pvc| pvc.dig('spec','storageClassName')=='longhorn' }, 'Protect Raft/audit data with Longhorn')
check(sts.dig('spec','persistentVolumeClaimRetentionPolicy') == {'whenDeleted'=>'Retain','whenScaled'=>'Retain'}, 'Vault claims must retain data')
check(vault.any? { |o| o['kind']=='PodDisruptionBudget' && o.dig('spec','maxUnavailable')==1 }, 'Vault must protect quorum during disruption')
check(vault.none? { |o| o['kind']=='Job' || o.dig('metadata','annotations','argocd.argoproj.io/hook')=='PostSync' }, 'No initialization/unseal readiness hooks')
config = vault.find { |o| o['kind']=='ConfigMap' }.fetch('data').values.join
check(config.include?('tls_cert_file') && !config.include?('tls_disable = 1'), 'Vault listener must use independent TLS')
csr = rendered.fetch('cert-manager-istio-csr')
certificate = csr.find { |o| o['kind']=='Certificate' }
check(certificate.dig('spec','issuerRef','name')=='vault-istio' && certificate.dig('spec','uris')==['spiffe://mgmt.thriftystack.internal/ns/istio-system/sa/istiod-service-account'], 'Istiod identity must use Vault issuer and management trust domain')
check(certificate.dig('spec','privateKey','rotationPolicy')=='Always' && certificate.dig('spec','renewBefore')=='30m', 'Istiod certificates must rotate automatically')
pdb = csr.find { |o| o['kind']=='PodDisruptionBudget' }
check(pdb, 'cert-manager-istio-csr must render a PodDisruptionBudget')
check(!(pdb.dig('spec').key?('minAvailable') && pdb.dig('spec').key?('maxUnavailable')), 'cert-manager-istio-csr PDB must not set both minAvailable and maxUnavailable')
istiod = rendered.fetch('istiod').find { |o| o['kind']=='Deployment' }
env = istiod.dig('spec','template','spec','containers')[0]['env']
check(env.any? { |e| e['name']=='ENABLE_CA_SERVER' && e['value']=='false' }, 'Istiod internal CA must be disabled')
check(istiod.dig('spec','template','spec','volumes').any? { |v| v.dig('secret','secretName')=='istiod-tls' }, 'Istiod must consume istio-csr control-plane certificate')
issuer = configuration('vault-issuer').find { |o| o['kind']=='Issuer' }
check(issuer.dig('spec','vault','path')=='pki-management/sign/istio' && issuer.dig('spec','vault','auth','kubernetes','serviceAccountRef','name')=='istio-vault-auth', 'Signer uses constrained intermediate and short-lived SA auth')
# Validate native cert-manager fields against the pinned chart CRD too.
issuer_crd = rendered['cert-manager'].find { |o| o['kind']=='CustomResourceDefinition' && o.dig('spec','names','kind')=='Issuer' }
validate(issuer['spec'], issuer_crd['spec']['versions'].find { |v| v['name']=='v1' }['schema']['openAPIV3Schema']['properties']['spec'], 'Vault Issuer')
strict = configuration('mesh-enrollment')
check(strict.all? { |o| o['kind']=='PeerAuthentication' && o.dig('metadata','namespace')=='mesh-test' && o.dig('spec','mtls','mode')=='STRICT' }, 'STRICT is scoped to enrolled workloads, never system namespaces')
provider = configuration('vault-provider').find { |o| o['kind']=='Provider' }
check(provider.dig('spec','package') == lock['vaultProvider']['package'], 'Provider package digest must match dependency lock')
check(provider.dig('spec','runtimeConfigRef','name')=='vault-provider', 'Provider must use its named SA/TLS runtime config')
check(configuration('vault-provider').any? { |o| o['kind']=='ValidatingAdmissionPolicyBinding' && o.dig('spec','validationActions')==['Deny'] }, 'Native protected resource deletion guard must remain enabled')
check(File.read("#{ROOT}/ops/promote.rb").include?("'--require-renewal'"), 'STRICT promotion requires natural renewal evidence')
puts "PKI/GitOps offline contracts: passed; rendered #{rendered.length} pinned charts and all custom Helm charts"
# Remote profile is inert by default and creates only namespaced cluster destinations when explicitly staged.
oci = "#{ROOT}/clusters/oci"
check(render(HELM,'template','unprofiled',CHART).empty?, 'Cluster-apps chart without a profile must render nothing')
check(render(HELM,'template','oci',CHART,*cluster_profile('oci')).empty?, 'Unconfigured OCI must render nothing')
remote_flags = ['--set','cluster.enabled=true','--set','cluster.prepared=true','--set','cluster.server=https://oci-api.invalid:6443','--set','cluster.vaultAddress=https://vault.private.invalid:8200']
remote_apps = render(HELM,'template','oci',CHART,*cluster_profile('oci'),*stage_flags,*remote_flags)
check(remote_apps.length==8, 'Workload cluster must not deploy management storage, Crossplane, Vault or root PKI')
remote_apps.each do |a|
  check(a.dig('metadata','name').start_with?('oci-') && a.dig('spec','project')=='oci', 'Remote Applications must be cluster-scoped')
  check(a.dig('spec','destination','server')=='https://oci-api.invalid:6443', 'Remote destination isolation')
  path="#{ROOT}/#{a.dig('spec','source','path')}"
  values=a.dig('spec','source','helm','valueFiles').flat_map { |f| ['-f',File.expand_path(f,path)] }
  objects=render(HELM,'template',a.dig('spec','source','helm','releaseName'),path,'--namespace',a.dig('spec','destination','namespace'),*values,*remote_flags)
  if a.dig('metadata','name')=='oci-cert-manager-istio-csr'
    c=objects.find { |o| o['kind']=='Certificate' }
    check(c.dig('spec','uris')==['spiffe://oci.thriftystack.internal/ns/istio-system/sa/istiod-service-account'], 'OCI must never use management SPIFFE identities')
  end
end
remote_declaration=render(HELM,'template','management',CHART,*cluster_profile('management'),'--set','stages.pki=true','--set','pkiClusters={oci}').find { |o| o['kind']=='Application' && o.dig('metadata','name')=='oci-vault-pki' }
check(remote_declaration.dig('spec','source','path')=='infrastructure/configuration/vault-pki' && remote_declaration.dig('spec','destination','server')=='https://kubernetes.default.svc', 'Remote PKI must remain centrally owned after layout changes')
remote_chart=File.join(ROOT,remote_declaration.dig('spec','source','path'))
check(remote_declaration.dig('spec','source','helm','valueFiles').all? { |p| File.file?(File.expand_path(p,remote_chart)) }, 'Remote PKI values paths must resolve from the relocated chart')
remote_pki=render(HELM,'template','oci-pki',"#{ROOT}/infrastructure/configuration/vault-pki",'-f',"#{oci}/cluster.yaml")
check(remote_pki.none? { |o| %w[SecretBackendRootCert ProviderConfig AuthBackendConfig].include?(o['kind']) }, 'Remote PKI must reuse central provider/root and cannot use the local reviewer')
check(remote_pki.find { |o| o['kind']=='SecretBackendRole' }.dig('spec','forProvider','allowedUriSans')==['spiffe://oci.thriftystack.internal/ns/*/sa/*'], 'OCI intermediate URI constraint')
check(remote_pki.find { |o| o['kind']=='SecretBackendRole' }.dig('metadata','name')=='oci-istio', 'Central PKI resources must not collide across clusters')
# Namespace admission, CSR address and storage policy selectors must still match actual dependency names.
check(sts.dig('metadata','name')=='vault' && sts.dig('spec','template','metadata','labels','app.kubernetes.io/name')=='vault','Wrapper must preserve Vault service and pod identities')
check(rendered['cert-manager'].any? { |o| o['kind']=='ServiceAccount' && o.dig('metadata','name')=='cert-manager' }, 'Vault token RBAC must bind the real controller SA')
check(csr.any? { |o| o['kind']=='Service' && o.dig('metadata','name')=='cert-manager-istio-csr' }, 'Istiod CA address must resolve to the rendered signer service')
puts 'Management and inactive/synthetic OCI Helm contracts: passed (no live registration or deployment)'
_, _, invalid = Open3.capture3(HELM,'template','oci',CHART,*cluster_profile('oci'),'--set','cluster.enabled=true')
check(!invalid.success?, 'Unprepared OCI activation must fail')
_, _, invalid = Open3.capture3(HELM,'template','wrong-domain',"#{ROOT}/infrastructure/charts/cert-manager-istio-csr",'-f',"#{oci}/cluster.yaml")
check(!invalid.success?, 'Management signer defaults must fail for an OCI cluster without domain overrides')

longhorn = rendered.fetch('longhorn')
check(longhorn.none? { |o| o['kind']=='Job' && o.dig('metadata','name')=='longhorn-pre-upgrade' }, 'Argo installation must not wait on a pre-upgrade job before SA/RBAC exists')
check(longhorn.any? { |o| o['kind']=='ServiceAccount' && o.dig('metadata','name')=='longhorn-service-account' }, 'Longhorn must install its service account normally')
checker = YAML.safe_load(File.read("#{ROOT}/infrastructure/charts/longhorn/values.yaml")).dig('longhorn','preUpgradeChecker')
check(checker['jobEnabled']==false && checker['upgradeVersionCheck']==true, 'Disable only the GitOps hook, keep upgrade safety enabled')
require_relative 'fleet-check'
workflow = YAML.safe_load(File.read("#{ROOT}/.github/workflows/validate.yaml"))
check(workflow['permissions']=={'contents'=>'read'}, 'Validation must have read-only repository permissions')
check(workflow['on'].keys.sort==%w[pull_request push workflow_dispatch], 'No privileged pull_request_target execution')
job=workflow.fetch('jobs').fetch('validate')
check(job['runs-on']=='ubuntu-24.04' && job['timeout-minutes']==15, 'Bound validation runtime')
steps=job.fetch('steps')
check(steps.select { |s| s['uses'] }.all? { |s| s['uses'].match?(/@[0-9a-f]{40}$/) && s.dig('with','persist-credentials')==false }, 'Pin actions and never persist write credentials')
check(steps.last['run'].include?('ruby ops/check.rb') && steps.last['run'].include?('python3 ops/verify-mesh.py --self-test'), 'CI must run the same offline contracts as operators')
puts 'Read-only GitOps PR validation workflow: passed'
