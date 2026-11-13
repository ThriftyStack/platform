#!/usr/bin/env ruby
# Offline contracts and exact artifact rendering; no cluster calls.
# The Authentik allowlist also reads public crossplane main and the
# provider-opentofu CRDs for the package version that root pins.
require 'yaml'
require 'json'
require 'digest'
require 'open3'
require 'tempfile'
require 'net/http'
require 'uri'
require 'openssl'
require_relative 'stages'
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
def authentik_restricted_container?(container, uid)
  context = container['securityContext'] || {}
  tmp = (container['volumeMounts'] || []).find { |mount| mount['mountPath']=='/tmp' }
  context['runAsNonRoot']==true && context['runAsUser']==uid && context['runAsGroup']==uid &&
    context['allowPrivilegeEscalation']==false && context['readOnlyRootFilesystem']==true &&
    context.dig('seccompProfile','type')=='RuntimeDefault' && context.dig('capabilities','drop')==['ALL'] &&
    (context.dig('capabilities','add') || []).empty? && tmp && tmp['name']=='tmp' && tmp['readOnly']!=true
end
def authentik_minio_tls?(pod, container_name, values)
  container = ((pod['initContainers'] || []) + (pod['containers'] || [])).find { |item| item['name']==container_name }
  return false unless container
  key = values.dig('backup','minio','listenerCaKey')
  bundle = (container['env'] || []).find { |env| env['name']=='AWS_CA_BUNDLE' }
  endpoint = (container['env'] || []).find { |env| env['name']=='ENDPOINT' }
  mount = (container['volumeMounts'] || []).find { |item| item['name']=='listener-ca' }
  volume = (pod['volumes'] || []).find { |item| item['name']=='listener-ca' }
  path = "/etc/ssl/minio-ca/#{key}"
  bundle && bundle['value']==path &&
    endpoint && endpoint['value']==values.dig('backup','minio','endpoint') &&
    mount && mount['mountPath']=='/etc/ssl/minio-ca' && mount['readOnly']==true &&
    volume && volume.dig('configMap','name')==values.dig('backup','minio','listenerCaConfigMap')
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
stage_flags = Ceremony::PROMOTABLE.flat_map { |s| ['--set', "stages.#{s}=true"] }
management_docs = render(HELM, 'template', 'management', CHART, *cluster_profile('management'), *stage_flags)
apps = management_docs.select { |o| o['kind']=='Application' }
by_name = apps.to_h { |a| [a['metadata']['name'], a] }
order = %w[longhorn crossplane vault-provider external-secrets reloader vault vault-pki cert-manager mesh-prerequisites vault-issuer cert-manager-istio-csr istio-base istiod mesh-qualification mesh-enrollment authentik crossplane-authentik cilium-bgp]
waves = order.map { |name| by_name.fetch(name).dig('metadata', 'annotations', 'argocd.argoproj.io/sync-wave').to_i }
check(waves.each_cons(2).all? { |a,b| a < b }, 'Dependency waves must follow deployment order')
authentik = by_name.fetch('crossplane-authentik')
authentik_source = authentik.dig('spec','source')
check(authentik_source['repoURL'] == 'https://github.com/ThriftyStack/crossplane.git', 'Authentik root must track the crossplane repository')
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
cilium_bgp = by_name.fetch('cilium-bgp')
check(cilium_bgp.dig('spec','syncPolicy','syncOptions').include?('SkipDryRunOnMissingResource=true'), 'cilium-bgp must apply when BGP CRDs are not installed yet')
check(cilium_bgp.dig('metadata','annotations','argocd.argoproj.io/sync-wave').to_i > authentik.dig('metadata','annotations','argocd.argoproj.io/sync-wave').to_i, 'cilium-bgp syncs after every earlier platform wave')
check(cilium_bgp.dig('spec','syncPolicy','automated') == {'prune' => false, 'selfHeal' => true}, 'cilium-bgp self-heals and does not prune')
check(cilium_bgp.dig('metadata','annotations','argocd.argoproj.io/sync-options') == 'Prune=false,Delete=false', 'cilium-bgp keeps prune and delete off')
check(cilium_bgp.dig('spec','destination','namespace') == 'cilium-bgp', 'cilium-bgp destination namespace')
project = management_docs.find { |o| o['kind']=='AppProject' && o.dig('metadata','name')=='management' }
check(project, 'Management AppProject must be rendered')
check(project.dig('spec','sourceRepos') == ['https://github.com/ThriftyStack/platform.git', 'https://github.com/ThriftyStack/crossplane.git'], 'Management project sources platform and crossplane')
check(project.dig('spec','clusterResourceWhitelist').none? { |r| r.values.include?('*') }, 'No wildcard management cluster privileges')
check(project.dig('spec','destinations').none? { |d| d['namespace'] == 'kube-system' }, 'Management project must not permit kube-system')
check(project.dig('spec','destinations').any? { |d| d == {'server' => 'https://kubernetes.default.svc', 'namespace' => 'crossplane-system'} }, 'Management project permits crossplane-system')
check(project.dig('metadata','annotations','argocd.argoproj.io/sync-wave').to_i < waves.first, 'Management project syncs before platform Applications')
app_namespaces = apps.map { |a| a.dig('spec','destination','namespace') }.uniq
project_namespaces = project.dig('spec','destinations').map { |d| d['namespace'] }
check(app_namespaces.all? { |ns| project_namespaces.include?(ns) }, 'Management project must allow every Application destination')
allow = project.dig('spec','clusterResourceWhitelist').map { |r| [r['group'], r['kind']] }
check(allow.none? { |group, _kind| group == 'external-secrets.io' }, 'Management allowlist contains no external-secrets.io group')
check(allow.include?(['opentofu.upbound.io', 'ProviderConfig']), 'Authentik ProviderConfig is cluster-scoped')
check(allow.include?(['opentofu.upbound.io', 'Workspace']), 'Authentik Workspace is cluster-scoped')
check(allow.include?(['pkg.crossplane.io', 'Provider']), 'Provider packages are cluster-scoped')
check(allow.include?(['pkg.crossplane.io', 'DeploymentRuntimeConfig']), 'Provider runtimes are cluster-scoped')
def fetch(url)
  uri = URI(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == 'https'
  http.open_timeout = 20
  http.read_timeout = 30
  request = Net::HTTP::Get.new(uri)
  request['User-Agent'] = 'thrifty-platform-fetch'
  request['Accept'] = 'application/vnd.github+json'
  token = ENV['GITHUB_TOKEN'] || ENV['GH_TOKEN']
  request['Authorization'] = "Bearer #{token}" if token && !token.empty?
  response = http.request(request)
  raise "GET #{url} failed: #{response.code}" unless response.is_a?(Net::HTTPSuccess)
  response.body
end
authentik_docs = JSON.parse(fetch('https://api.github.com/repos/ThriftyStack/crossplane/contents/deploy/authentik?ref=main')).select { |entry| entry['name'].end_with?('.yaml') }.flat_map do |entry|
  documents(fetch(entry['download_url']))
end
authentik_docs.select! { |object| object.is_a?(Hash) && object['apiVersion'] && object['kind'] }
provider_package = authentik_docs.find { |object| object['kind'] == 'Provider' }.dig('spec', 'package')
check(provider_package.start_with?('xpkg.upbound.io/upbound/provider-opentofu:'), 'Authentik provider package must be provider-opentofu')
provider_version = provider_package.split(':', 2).last
check(provider_version.match?(/\Av\d+\.\d+\.\d+\z/), 'Authentik provider version must be a release tag')
opentofu_scope = JSON.parse(fetch("https://api.github.com/repos/upbound/provider-opentofu/contents/package/crds?ref=#{provider_version}")).select { |entry| entry['name'].start_with?('opentofu.upbound.io_') }.to_h do |entry|
  crd = YAML.safe_load(fetch(entry['download_url']), aliases: true)
  [[crd.dig('spec', 'group'), crd.dig('spec', 'names', 'kind')], crd.dig('spec', 'scope')]
end
pkg_scope = {
  ['pkg.crossplane.io', 'Provider'] => 'Cluster',
  ['pkg.crossplane.io', 'DeploymentRuntimeConfig'] => 'Cluster'
}
authentik_docs.each do |object|
  group = object['apiVersion'].include?('/') ? object['apiVersion'].split('/')[0] : ''
  kind = object['kind']
  scope = pkg_scope[[group, kind]] || opentofu_scope[[group, kind]]
  check(scope, "No scope for crossplane #{group}/#{kind} at provider-opentofu #{provider_version}")
  check(allow.include?([group, kind]), "Management project must allow #{group}/#{kind}") if scope == 'Cluster'
end
def ignores?(app, group, kind)
  (app.dig('spec', 'ignoreDifferences') || []).any? { |d| d['group'] == group && d['kind'] == kind }
end
check(ignores?(by_name.fetch('vault-pki'), 'vault.upbound.io', 'ProviderConfig'), 'vault-pki must ignore ProviderConfig header drift')
check(ignores?(by_name.fetch('istio-base'), 'admissionregistration.k8s.io', 'ValidatingWebhookConfiguration'), 'istio-base must ignore validating webhook drift')
check(ignores?(by_name.fetch('istiod'), 'admissionregistration.k8s.io', 'ValidatingWebhookConfiguration'), 'istiod must ignore validating webhook drift')
check(ignores?(by_name.fetch('istiod'), 'admissionregistration.k8s.io', 'MutatingWebhookConfiguration'), 'istiod must ignore mutating webhook drift')
eso_app = by_name.fetch('external-secrets')
webhook_ignore = (eso_app.dig('spec', 'ignoreDifferences') || []).find { |d| d['group'] == 'admissionregistration.k8s.io' && d['kind'] == 'ValidatingWebhookConfiguration' }
check(webhook_ignore && (webhook_ignore['jqPathExpressions'] || []).include?('.webhooks[]?.clientConfig.caBundle'), 'external-secrets must ignore webhook caBundle drift')
secret_ignore = (eso_app.dig('spec', 'ignoreDifferences') || []).find { |d| d['group'] == '' && d['kind'] == 'Secret' }
check(secret_ignore && secret_ignore['name'] == 'external-secrets-webhook' && (secret_ignore['jsonPointers'] || []).include?('/data'), 'external-secrets must ignore webhook Secret data')
%w[external-secrets reloader].each do |name|
  labels = by_name.fetch(name).dig('spec', 'syncPolicy', 'managedNamespaceMetadata', 'labels')
  check(labels == { 'istio-injection' => 'disabled' }, "#{name} namespace label is only istio-injection disabled")
end
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
    check(app.dig('metadata','name') == 'crossplane-authentik', 'Only the Authentik root may use a directory source')
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
  'DeploymentRuntimeConfig' => 'pkg.crossplane.io',
  'CiliumLoadBalancerIPPool' => 'cilium.io',
  'CiliumBGPAdvertisement' => 'cilium.io',
  'CiliumBGPPeerConfig' => 'cilium.io',
  'CiliumBGPClusterConfig' => 'cilium.io'
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
oci_pin = %w[
  oci-cert-manager oci-mesh-prerequisites oci-vault-issuer
  oci-cert-manager-istio-csr oci-istio-base oci-istiod
  oci-mesh-qualification oci-mesh-enrollment
  oci-external-secrets oci-reloader
]
rendered_names = remote_apps.map { |a| a.dig('metadata', 'name') }.sort
check(rendered_names == oci_pin.sort, 'Workload cluster renders the role-less certificate, mesh, and secrets apps')
catalog = YAML.safe_load(File.read("#{ROOT}/charts/cluster-apps/values.yaml")).fetch('services')
derived = catalog.select { |s| s['role'].nil? && Ceremony::PROMOTABLE.include?(s['stage']) }.map { |s| "oci-#{s['name']}" }.sort
check(derived == oci_pin.sort, 'OCI pin drifted from role-less services in stage_flags')
%w[external-secrets reloader].each do |name|
  row = catalog.find { |s| s['name'] == name }
  check(row && row['role'].nil? && row['stage'] == 'secrets', "#{name} stays a role-less secrets service")
end
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
authentik_role = rendered.fetch('vault-pki').find { |o| o['kind']=='AuthBackendRole' && o.dig('metadata','name')=='authentik-tofu' }
check(authentik_role, 'Management Vault must issue an Authentik OpenTofu Kubernetes role')
check(authentik_role.dig('spec','forProvider','backend')=='kubernetes-management', 'Authentik OpenTofu role uses the management Kubernetes auth mount')
check(authentik_role.dig('spec','forProvider','boundServiceAccountNames')==['provider-opentofu'], 'Authentik OpenTofu role is bound to the OpenTofu provider')
check(authentik_role.dig('spec','forProvider','boundServiceAccountNamespaces')==['crossplane-system'], 'Authentik OpenTofu role is bound to crossplane-system')
check(authentik_role.dig('spec','forProvider','audience')=='vault://crossplane-system/authentik-tofu', 'Authentik OpenTofu role audience must match the projected token')
check(authentik_role.dig('spec','forProvider','tokenPolicies')==['authentik-tofu'] && authentik_role.dig('spec','forProvider','tokenNoDefaultPolicy')==true, 'Authentik OpenTofu tokens carry only their named policy')
check(authentik_role.dig('spec','forProvider','tokenTtl')==3600 && authentik_role.dig('spec','forProvider','tokenMaxTtl')==3600, 'Authentik OpenTofu tokens expire within an hour')
authentik_policy = rendered.fetch('vault-pki').find { |o| o['kind']=='Policy' && o.dig('metadata','name')=='authentik-tofu' }
check(authentik_policy, 'Management Vault must define the Authentik OpenTofu policy')
check(authentik_policy.dig('spec','forProvider','policy').include?('path "infra/data/authentik"') && authentik_policy.dig('spec','forProvider','policy').include?('path "auth/token/create"'), 'Authentik OpenTofu policy reads its KV paths and can create a child token')
check(remote_pki.none? { |o| o.dig('metadata','name')=='authentik-tofu' }, 'Spoke PKI must not grant the Authentik OpenTofu role')
authentik_app = by_name.fetch('authentik')
check(authentik_app.dig('spec','source','path')=='infrastructure/charts/authentik', 'Authentik runtime chart path')
check(authentik_app.dig('spec','destination','namespace')=='authentik', 'Authentik runtime deploys to namespace authentik')
check(authentik_app.dig('metadata','annotations','argocd.argoproj.io/sync-wave').to_i < by_name.fetch('crossplane-authentik').dig('metadata','annotations','argocd.argoproj.io/sync-wave').to_i, 'Authentik runtime must sync before identity Workspace')
authentik_runtime = rendered.fetch('authentik')
check(authentik_runtime.any? { |o| o['kind']=='Service' && o.dig('spec','type')=='NodePort' && (o.dig('spec','ports')||[]).any? { |p| p['nodePort']==30080 } }, 'Authentik server exposes HTTP NodePort 30080 for the Cloudflare tunnel')
authentik_values = YAML.safe_load(File.read("#{ROOT}/infrastructure/charts/authentik/values.yaml"))
media = authentik_runtime.find { |o| o['kind']=='PersistentVolumeClaim' && o.dig('metadata','name')==authentik_values.dig('media','claimName') }
check(media && media.dig('spec','storageClassName')=='longhorn' && media.dig('spec','accessModes')==['ReadWriteOnce'] && media.dig('spec','resources','requests','storage')=='1Gi', 'Authentik media PVC is Longhorn RWO 1Gi')
def authentik_mounts_data?(object)
  containers = object.dig('spec','template','spec','containers') || []
  containers.any? { |container| (container['volumeMounts'] || []).any? { |mount| mount['name']=='data' && mount['mountPath']=='/data' } }
end
authentik_server = authentik_runtime.find { |o| o['kind']=='Deployment' && o.dig('metadata','name')=='authentik-server' }
authentik_worker = authentik_runtime.find { |o| o['kind']=='Deployment' && o.dig('metadata','name')=='authentik-worker' }
check(authentik_mounts_data?(authentik_server) && authentik_mounts_data?(authentik_worker), 'Authentik server and worker mount the media PVC at /data')
server_claim = (authentik_server.dig('spec','template','spec','volumes') || []).find { |volume| volume['name']=='data' }
worker_claim = (authentik_worker.dig('spec','template','spec','volumes') || []).find { |volume| volume['name']=='data' }
check(server_claim&.dig('persistentVolumeClaim','claimName')==authentik_values.dig('media','claimName') && worker_claim&.dig('persistentVolumeClaim','claimName')==authentik_values.dig('media','claimName'), 'Authentik server and worker mount the wrapper media PVC')
[authentik_server, authentik_worker].each do |deploy|
  strategy = deploy.dig('spec','strategy') || {}
  sync_options = deploy.dig('metadata','annotations','argocd.argoproj.io/sync-options').to_s.split(',').map(&:strip)
  check(strategy['type']=='Recreate' && !strategy.key?('rollingUpdate'), "#{deploy.dig('metadata','name')} uses Recreate with no rollingUpdate")
  check(sync_options.include?('Replace=true') && sync_options.include?('ServerSideApply=false'), "#{deploy.dig('metadata','name')} is replaced so a live rollingUpdate is cleared")
end
check(authentik_server.dig('spec','template','spec','securityContext','fsGroup')==1000 && authentik_worker.dig('spec','template','spec','securityContext','fsGroup')==1000, 'Authentik media volume is writable by uid 1000')
worker_affinity = authentik_worker.dig('spec','template','spec','affinity','podAffinity','requiredDuringSchedulingIgnoredDuringExecution') || []
check(worker_affinity.any? { |term| term['topologyKey']=='kubernetes.io/hostname' && term.dig('labelSelector','matchLabels','app.kubernetes.io/component')=='server' }, 'Authentik worker shares the server node so both can mount RWO media')
backup_job = authentik_runtime.find { |o| o['kind']=='CronJob' && o.dig('metadata','name')=='authentik-backup' }
check(backup_job && backup_job.dig('spec','schedule')=='15 3 * * *' && backup_job.dig('spec','suspend')!=true && backup_job.dig('spec','concurrencyPolicy')=='Forbid', 'Authentik backup CronJob is a nightly exclusive run')
check(backup_job.dig('spec','failedJobsHistoryLimit').to_i >= 3, 'Authentik backup keeps at least three failed Jobs')
check(backup_job.dig('spec','jobTemplate','spec','template','spec','restartPolicy')=='Never', 'Authentik backup Job does not restart a failed container in the same pod')
backup_pod = backup_job.dig('spec','jobTemplate','spec','template','spec')
backup_affinity = backup_pod.dig('affinity','podAffinity','requiredDuringSchedulingIgnoredDuringExecution') || []
check(backup_affinity.any? { |term| term['topologyKey']=='kubernetes.io/hostname' && term.dig('labelSelector','matchLabels','app.kubernetes.io/component')=='server' }, 'Authentik backup pod is pinned to the server node for the RWO media volume')
backup_media = (backup_pod['volumes'] || []).find { |volume| volume['name']=='media' }
check(backup_media && backup_media.dig('persistentVolumeClaim','claimName')==authentik_values.dig('media','claimName') && backup_media.dig('persistentVolumeClaim','readOnly')==true, 'Authentik backup mounts the media PVC read-only')
dump = (backup_pod['initContainers'] || []).find { |container| container['name']=='dump' }
dump_media = dump && (dump['volumeMounts'] || []).find { |mount| mount['mountPath']=='/data' }
check(dump && dump['image']==authentik_values.dig('backup','images','postgres') && dump_media && dump_media['readOnly']==true, 'Authentik backup dumps with the bundled Postgres image and a read-only media mount')
recipient_env = dump && (dump['env'] || []).find { |env| env['name']=='AGE_RECIPIENT' }
check(recipient_env && recipient_env['value']==authentik_values.dig('backup','ageRecipient'), 'Authentik backup age recipient comes from values')
scripts = authentik_runtime.find { |o| o['kind']=='ConfigMap' && o.dig('metadata','name')=='authentik-backup-scripts' }
check(scripts, 'Authentik backup scripts ConfigMap is rendered')
dump_script = scripts.dig('data','dump.sh').to_s
check(dump_script.include?('age recipient is still the placeholder age1REPLACE_ME') && dump_script.index('age1REPLACE_ME') < dump_script.index('pg_dump'), 'Authentik backup rejects the placeholder age recipient before pg_dump')
check(dump_script.include?('pg_dump') && dump_script.include?('-Fc'), 'Authentik backup uses pg_dump custom format')
check(dump_script.include?('tar --warning=no-file-changed') && dump_script.include?('|| status=$?') && !dump_script.include?('set +e'), 'Authentik backup tolerates tar exit 1 without tripping the ERR trap')
upload_script = scripts.dig('data','upload.sh').to_s
check(upload_script.include?('COMPLETE') && !upload_script.match?(/s3\s+rm|s3api\s+delete|s3\s+rb|mc\s+rm/), 'Authentik backup uploads COMPLETE and does not delete bucket objects')
check(upload_script.include?('ls -la /work/plain') && upload_script.include?('uploading '), 'Authentik upload names the missing file and the object it is uploading')
check(!upload_script.include?('no-verify-ssl') && !upload_script.include?('no-verify'), 'Authentik upload keeps TLS verification on')
fetch_script = scripts.dig('data','fetch.sh').to_s
check(fetch_script.include?('ls -la /work/enc') && fetch_script.include?('downloading '), 'Authentik fetch names a missing download before it exits')
check(!fetch_script.include?('no-verify-ssl') && !fetch_script.include?('no-verify'), 'Authentik fetch keeps TLS verification on')
restore_script_body = scripts.dig('data','restore.sh').to_s
check(restore_script_body.include?('ls -la /work/plain') && restore_script_body.include?('restoring '), 'Authentik restore names a missing dump before pg_restore')
check(authentik_runtime.none? { |o| o['kind']=='Secret' && o.dig('metadata','name')==authentik_values.dig('backup','minio','secretName') }, 'Authentik MinIO credentials are not rendered as a Secret')
external_secret = authentik_runtime.find { |o| o['kind']=='ExternalSecret' && o.dig('metadata','name')==authentik_values.dig('backup','minio','secretName') }
check(external_secret && external_secret.dig('spec','secretStoreRef','name')=='oke-vault' && external_secret.dig('spec','secretStoreRef','kind')=='SecretStore', 'Authentik backup MinIO ExternalSecret uses the namespaced SecretStore')
check(external_secret.dig('metadata','namespace')=='authentik', 'Authentik backup ExternalSecret stays in namespace authentik')
check((external_secret.dig('spec','data') || []).all? { |row| row.dig('remoteRef','key')=='authentik/backup-minio' }, 'Authentik backup MinIO key is authentik/backup-minio under the infra mount')
check(authentik_runtime.none? { |o| o['kind']=='ClusterSecretStore' }, 'Authentik chart does not render a ClusterSecretStore')
store = authentik_runtime.find { |o| o['kind']=='SecretStore' && o.dig('metadata','name')=='oke-vault' }
vault = store && store.dig('spec','provider','vault')
check(store && store.dig('metadata','namespace')=='authentik', 'SecretStore oke-vault is namespaced to authentik')
check(vault && vault['server']=='https://vault.devoops.uk' && vault['path']=='infra' && vault['version']=='v2', 'SecretStore reads estate Vault KV v2 mount infra')
ca_provider = vault && vault['caProvider']
check(ca_provider == {'type'=>'ConfigMap','name'=>'oke-vault-listener-ca','key'=>'ca.crt'}, 'SecretStore trusts the namespaced listener CA ConfigMap')
jwt = vault && vault.dig('auth','jwt')
check(jwt && jwt['path']=='jwt-management' && jwt['role']=='authentik_authentik-eso', 'SecretStore uses jwt-management role authentik_authentik-eso')
token_ref = jwt && jwt.dig('kubernetesServiceAccountToken','serviceAccountRef')
check(token_ref && token_ref['name']=='authentik-eso' && token_ref['audiences']==['vault-oke'], 'SecretStore token audience is vault-oke for ServiceAccount authentik-eso')
eso_sa = authentik_runtime.find { |o| o['kind']=='ServiceAccount' && o.dig('metadata','name')=='authentik-eso' }
check(eso_sa && eso_sa.dig('metadata','namespace')=='authentik' && eso_sa['automountServiceAccountToken']==false, 'authentik-eso does not mount a token')
token_role = authentik_runtime.find { |o| o['kind']=='Role' && o.dig('metadata','name')=='authentik-eso-token' }
token_rule = token_role && token_role.fetch('rules').find { |rule| (rule['resources'] || []).include?('serviceaccounts/token') }
check(token_role && token_role.dig('metadata','namespace')=='authentik' && token_rule && token_rule['verbs']==['create'] && token_rule['resourceNames']==['authentik-eso'], 'Only the External Secrets controller can mint an authentik-eso token')
token_binding = authentik_runtime.find { |o| o['kind']=='RoleBinding' && o.dig('metadata','name')=='authentik-eso-token' }
eso_controller = rendered.fetch('external-secrets').find { |o| o['kind']=='Deployment' && o.dig('metadata','name')=='external-secrets' }
controller_sa = eso_controller.dig('spec','template','spec','serviceAccountName')
check(controller_sa=='external-secrets' && eso_controller.dig('metadata','namespace')=='external-secrets', 'External Secrets controller ServiceAccount is external-secrets/external-secrets')
check(token_binding && token_binding.dig('subjects')==[{'kind'=>'ServiceAccount','name'=>controller_sa,'namespace'=>eso_controller.dig('metadata','namespace')}], 'Token RoleBinding names the rendered External Secrets controller ServiceAccount')
listener_ca = authentik_runtime.find { |o| o['kind']=='ConfigMap' && o.dig('metadata','name')=='oke-vault-listener-ca' }
check(listener_ca && listener_ca.dig('metadata','namespace')=='authentik' && listener_ca.dig('data','ca.crt'), 'OKE Vault listener CA ConfigMap is in namespace authentik')
check(!authentik_runtime.to_json.include?('AGE-SECRET-KEY'), 'Authentik render contains no age identity')
check(authentik_values.dig('backup','ageRecipient')=='age1s7npftgtwq3ylwy5cpyederc3tawwgz2shdrr9m8csrs85e5d4ysx0e9y5', 'Authentik backup recipient is the offline public key')
check(authentik_values.dig('backup','ageRecipient')!='age1REPLACE_ME', 'Authentik backup recipient is not the placeholder')
restore_job = authentik_runtime.find { |o| o['kind']=='CronJob' && o.dig('metadata','name')=='authentik-backup-restore-test' }
check(restore_job && restore_job.dig('spec','suspend')==true, 'Authentik restore-test CronJob is suspended')
restore_pod = restore_job.dig('spec','jobTemplate','spec','template','spec')
check(authentik_values.dig('backup','minio','endpoint')=='https://s3.adminio.biz:9000', 'Authentik MinIO endpoint stays https://s3.adminio.biz:9000')
check(authentik_minio_tls?(backup_pod, 'upload', authentik_values), 'Authentik upload sets AWS_CA_BUNDLE and mounts the listener CA read-only')
check(authentik_minio_tls?(restore_pod, 'fetch', authentik_values), 'Authentik fetch sets AWS_CA_BUNDLE and mounts the listener CA read-only')
postgres_sidecar = (restore_pod['initContainers'] || []).find { |container| container['name']=='postgres' }
check(postgres_sidecar && postgres_sidecar['restartPolicy']=='Always', 'Throwaway Postgres is a native sidecar so the restore Job can complete')
check((restore_pod['containers'] || []).map { |container| container['name'] }==['restore'], 'Restore test has one app container so Job success follows restore.sh')
[backup_pod, restore_pod].each do |pod|
  context = pod['securityContext'] || {}
  check(context['runAsNonRoot']==true && context['runAsUser']==1000 && context['runAsGroup']==1000 && context['fsGroup']==1000 && context.dig('seccompProfile','type')=='RuntimeDefault', 'Authentik backup pods run as uid 1000 under restricted PodSecurity')
  tmp_volume = (pod['volumes'] || []).find { |volume| volume['name']=='tmp' }
  check(tmp_volume && tmp_volume['emptyDir'], 'Authentik backup pods give containers a writable emptyDir at /tmp')
  containers = (pod['initContainers'] || []) + (pod['containers'] || [])
  containers.each do |container|
    uid = container['name']=='postgres' ? 999 : 1000
    check(authentik_restricted_container?(container, uid), "Authentik #{container['name']} meets restricted PodSecurity as uid #{uid}")
  end
end
postgres_data = (postgres_sidecar['volumeMounts'] || []).find { |mount| mount['mountPath']=='/var/lib/postgresql/data' }
postgres_socket = (postgres_sidecar['volumeMounts'] || []).find { |mount| mount['mountPath']=='/var/run/postgresql' }
check(postgres_data && postgres_data['name']=='pgdata' && postgres_socket && postgres_socket['name']=='pgrun', 'Throwaway Postgres keeps writable data and socket directories')
%w[pgdata pgrun].each do |name|
  volume = (restore_pod['volumes'] || []).find { |item| item['name']==name }
  check(volume && volume['emptyDir'], "Throwaway Postgres #{name} is an emptyDir")
end
restore_script = scripts.dig('data','restore.sh').to_s
check(restore_script.include?('pg_restore') && restore_script.include?('authentik_core_user'), 'Authentik restore-test restores into throwaway Postgres and counts authentik_core_user')
# Namespace admission, CSR address and storage policy selectors must still match actual dependency names.
check(sts.dig('metadata','name')=='vault' && sts.dig('spec','template','metadata','labels','app.kubernetes.io/name')=='vault','Wrapper must preserve Vault service and pod identities')
check(rendered['cert-manager'].any? { |o| o['kind']=='ServiceAccount' && o.dig('metadata','name')=='cert-manager' }, 'Vault token RBAC must bind the real controller SA')
check(csr.any? { |o| o['kind']=='Service' && o.dig('metadata','name')=='cert-manager-istio-csr' }, 'Istiod CA address must resolve to the rendered signer service')
eso = rendered.fetch('external-secrets')
check(eso.none? { |o| %w[SecretStore ClusterSecretStore ExternalSecret ClusterExternalSecret].include?(o['kind']) }, 'secrets stage installs operators only')
check(eso.none? { |o| o.dig('metadata', 'namespace') == 'kube-system' }, 'external-secrets must not use kube-system')
check(eso.any? { |o| o['kind'] == 'CustomResourceDefinition' && o.dig('spec', 'group') == 'external-secrets.io' }, 'external-secrets chart includes an external-secrets.io CRD')
check(eso.none? { |o| o['kind'] == 'Certificate' }, 'external-secrets renders no Certificate')
ctrl = eso.find { |o| o['kind'] == 'Deployment' && o.dig('metadata', 'name') == 'external-secrets' }
ctrl_args = ctrl.dig('spec', 'template', 'spec', 'containers').find { |c| c['name'] == 'external-secrets' }.fetch('args')
check(ctrl_args.include?('--enable-leader-election=true'), 'external-secrets elects a leader in its namespace')
check(ctrl_args.none? { |arg| arg.include?('kube-system') }, 'leader election args must not name kube-system')
lead = eso.find { |o| o['kind'] == 'Role' && o.dig('metadata', 'name') == 'external-secrets-leaderelection' }
check(lead && lead.dig('metadata', 'namespace') == 'external-secrets', 'leader election Role stays in external-secrets')
check(lead.fetch('rules').any? { |rule| (rule['resources'] || []).include?('leases') }, 'leader election Role grants leases')
placeholder = eso.find { |o| o['kind'] == 'ConfigMap' && o.dig('metadata', 'name') == 'oke-vault-listener-ca' }
check(placeholder && placeholder.dig('metadata', 'namespace') == 'external-secrets', 'listener CA placeholder is named and namespaced')
body = placeholder.dig('data', 'ca.crt').to_s
check(body == 'PLACEHOLDER_NOT_A_CERTIFICATE', 'placeholder is exactly PLACEHOLDER_NOT_A_CERTIFICATE')
check(eso.none? { |o| o['kind'] == 'Deployment' && o.to_json.include?('oke-vault-listener-ca') }, 'do not mount the placeholder')
webhook_secret = eso.find { |o| o['kind'] == 'Secret' && o.dig('metadata', 'name') == 'external-secrets-webhook' }
check(webhook_secret && webhook_secret['data'].nil?, 'webhook secret data belongs to certController')
%w[external-secrets external-secrets-webhook external-secrets-cert-controller].each do |deploy_name|
  deploy = eso.find { |o| o['kind'] == 'Deployment' && o.dig('metadata', 'name') == deploy_name }
  check(deploy && deploy.dig('spec', 'replicas') == 2, "#{deploy_name} replicaCount is 2")
  container = deploy.dig('spec', 'template', 'spec', 'containers').first
  resources = container.fetch('resources')
  check(resources.dig('requests', 'cpu') == '50m' && resources.dig('requests', 'memory') == '128Mi', "#{deploy_name} requests")
  check(resources.dig('limits', 'memory') == '384Mi' && !resources.fetch('limits').key?('cpu'), "#{deploy_name} memory limit and no cpu limit")
  spreads = deploy.dig('spec', 'template', 'spec', 'topologySpreadConstraints')
  selector = spreads && spreads[0] && spreads[0].dig('labelSelector', 'matchLabels')
  pod_labels = deploy.dig('spec', 'template', 'metadata', 'labels')
  check(spreads && spreads.length == 1 && selector && !selector.empty? && selector.all? { |key, value| pod_labels[key] == value }, "#{deploy_name} topology selector matches its pod labels")
end
reloader = rendered.fetch('reloader')
check(reloader.none? { |o| o.dig('metadata', 'namespace') == 'kube-system' }, 'reloader must not use kube-system')
check(reloader.none? { |o| o['kind'] == 'Certificate' }, 'reloader renders no Certificate')
rel_dep = reloader.find { |o| o['kind'] == 'Deployment' }
check(rel_dep && rel_dep.dig('metadata', 'name') == 'reloader' && rel_dep.dig('spec', 'replicas') == 2, 'reloader fullnameOverride and HA replicas')
rel_container = rel_dep.dig('spec', 'template', 'spec', 'containers').find { |c| c['name'] == 'reloader' }
rel_resources = rel_container.fetch('resources')
check(rel_resources.dig('requests', 'cpu') == '50m' && rel_resources.dig('requests', 'memory') == '128Mi', 'reloader requests')
check(rel_resources.dig('limits', 'memory') == '384Mi' && !rel_resources.fetch('limits').key?('cpu'), 'reloader memory limit and no cpu limit')
gomax = rel_container.fetch('env').find { |e| e['name'] == 'GOMAXPROCS' }
check(gomax && gomax['value'] == '0' && gomax['valueFrom'].nil?, 'reloader must not read a missing cpu limit')
check(rel_container.fetch('args').include?('--enable-ha=true'), 'reloader leader election via enableHA')
rel_spreads = rel_dep.dig('spec', 'template', 'spec', 'topologySpreadConstraints')
rel_selector = rel_spreads && rel_spreads[0] && rel_spreads[0].dig('labelSelector', 'matchLabels')
rel_labels = rel_dep.dig('spec', 'template', 'metadata', 'labels')
check(rel_spreads && rel_spreads.length == 1 && rel_selector && !rel_selector.empty? && rel_selector.all? { |key, value| rel_labels[key] == value }, 'reloader topology selector matches its pod labels')
bgp = rendered.fetch('cilium-bgp')
check(bgp.none? { |o| o['kind'] == 'Service' && o.dig('spec', 'type') == 'LoadBalancer' }, 'cilium-bgp renders no LoadBalancer Service')
check(bgp.none? { |o| o.dig('metadata', 'namespace') == 'kube-system' }, 'cilium-bgp must not use kube-system')
pool = bgp.find { |o| o['kind'] == 'CiliumLoadBalancerIPPool' }
check(pool && pool.dig('metadata', 'name') == 'mgmt-internal', 'LB pool name')
check(pool.dig('spec', 'blocks') == [{'cidr' => '10.0.50.0/28'}], 'pool CIDR is 10.0.50.0/28')
check(pool.dig('spec', 'allowFirstLastIPs') == 'No', 'LB pool reserves the first and last addresses')
check(pool.dig('spec', 'serviceSelector', 'matchLabels') == {'thriftystack.io/lb-pool' => 'mgmt-internal'}, 'LB pool selects thriftystack.io/lb-pool=mgmt-internal')
advertisement = bgp.find { |o| o['kind'] == 'CiliumBGPAdvertisement' }
check(advertisement && advertisement.dig('metadata', 'name') == 'mgmt-lb', 'BGP advertisement name')
check(advertisement.dig('metadata', 'labels', 'advertise') == 'bgp', 'BGP advertisement carries advertise=bgp')
ads = advertisement.dig('spec', 'advertisements')
check(ads && ads.length == 1 && ads[0]['advertisementType'] == 'Service', 'BGP advertises Services only')
check(ads[0].dig('service', 'addresses') == ['LoadBalancerIP'], 'only LoadBalancerIP advertised')
check(ads[0].dig('selector', 'matchLabels') == {'thriftystack.io/lb-pool' => 'mgmt-internal'}, 'BGP advertisement selects the management LB pool label')
check(bgp.none? { |o| o.to_json.include?('PodCIDR') }, 'do not advertise PodCIDR')
peer = bgp.find { |o| o['kind'] == 'CiliumBGPPeerConfig' }
check(peer && peer.dig('metadata', 'name') == 'unifi-gateway', 'UniFi peer config name')
check(peer.dig('spec', 'families') == [{'afi' => 'ipv4', 'safi' => 'unicast', 'advertisements' => {'matchLabels' => {'advertise' => 'bgp'}}}], 'UniFi peer selects ipv4 unicast advertise=bgp')
check(peer.dig('spec', 'gracefulRestart') == {'enabled' => true, 'restartTimeSeconds' => 15}, 'UniFi peer graceful restart is 15s')
check(peer.dig('spec', 'timers', 'holdTimeSeconds') == 9 && peer.dig('spec', 'timers', 'keepAliveTimeSeconds') == 3, 'UniFi peer timers are hold 9 keepalive 3')
cluster_bgp = bgp.find { |o| o['kind'] == 'CiliumBGPClusterConfig' }
check(cluster_bgp && cluster_bgp.dig('metadata', 'name') == 'mgmt', 'BGP cluster config name')
check(cluster_bgp.dig('spec', 'nodeSelector', 'matchLabels') == {'kubernetes.io/os' => 'linux'}, 'BGP runs on Linux nodes')
instances = cluster_bgp.dig('spec', 'bgpInstances')
check(instances && instances.length == 1 && instances[0]['name'] == 'mgmt' && instances[0]['localASN'] == 65030, 'local ASN is 65030')
check(advertisement.dig('metadata', 'annotations', 'argocd.argoproj.io/sync-wave') == '0', 'advertisements sync before the cluster config')
check(peer.dig('metadata', 'annotations', 'argocd.argoproj.io/sync-wave') == '0', 'peer config syncs before the cluster config')
check(cluster_bgp.dig('metadata', 'annotations', 'argocd.argoproj.io/sync-wave') == '1', 'cluster config syncs after the peer it references')
check(!instances[0].key?('localPort'), 'BGP instance sets no localPort')
check(instances[0]['peers'] == [{'name' => 'unifi', 'peerASN' => 65020, 'peerAddress' => '10.0.10.254', 'peerConfigRef' => {'name' => 'unifi-gateway'}}], 'UniFi peer ASN is 65020')
%w[CiliumLoadBalancerIPPool CiliumBGPAdvertisement CiliumBGPPeerConfig CiliumBGPClusterConfig].each do |kind|
  check(allow.include?(['cilium.io', kind]), "Management project must allow cilium.io/#{kind}")
end
bgp_row = catalog.find { |s| s['name'] == 'cilium-bgp' }
check(bgp_row && bgp_row['role'] == 'management' && bgp_row['stage'] == 'bgp', 'cilium-bgp stays a management bgp service')
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
ceremony = YAML.safe_load(File.read("#{ROOT}/.github/workflows/ceremony-promote.yaml"))
workflow_options = ceremony.dig('on', 'workflow_dispatch', 'inputs', 'stage', 'options')
check(workflow_options == Ceremony::PROMOTE_PR, 'ceremony-promote options must match Ceremony::PROMOTE_PR')
hints = File.read("#{ROOT}/Makefile").scan(/echo 'Set STAGE=<([^>]+)>'/).flatten
check(hints == [Ceremony::PROMOTABLE.join('|'), Ceremony::PROMOTE_PR.join('|')], 'Makefile stage hints must match ops/stages.rb')
validation = File.read("#{ROOT}/charts/cluster-apps/templates/validation.yaml")
check(!validation.include?('secrets'), 'validation.yaml must not chain the secrets stage')
check(!validation.include?('bgp'), 'validation.yaml must not chain the bgp stage')

monitoring = rendered.fetch('monitoring')
agent_role = monitoring.find { |o| o['kind'] == 'ClusterRole' && o.dig('metadata', 'name') == 'management-vmagent' }
check(agent_role && agent_role.fetch('rules').none? { |rule| (rule['resources'] || []).any? { |r| ['secrets', 'nodes/proxy', '*'].include?(r) } }, 'Management metrics must not grant secrets or kubelet proxy access')
agent = monitoring.find { |o| o['kind'] == 'Deployment' && o.dig('metadata', 'name') == 'vmagent' }
args = agent.dig('spec', 'template', 'spec', 'containers', 0, 'args')
check(args.include?('-remoteWrite.url=https://metrics.adminio.biz/api/v1/write'), 'Management metrics use the existing HTTPS receiver')
check(args.include?('-remoteWrite.maxDiskUsagePerURL=1GiB'), 'Management metrics queue is bounded')
config = monitoring.find { |o| o['kind'] == 'ConfigMap' }.dig('data', 'scrape.yml')
scrape = YAML.safe_load(config)
check(scrape.dig('global', 'external_labels') == {'cluster'=>'management', 'site'=>'home'}, 'Management series cannot collide with OKE series')
cadvisor = scrape.fetch('scrape_configs').find { |j| j['job_name'] == 'management-cadvisor' }
check(cadvisor['scheme'] == 'https' && cadvisor.dig('tls_config', 'ca_file') && !config.include?('insecure_skip_verify'), 'Kubelet TLS is verified with the mounted cluster CA')
check(monitoring.none? { |o| ['Service', 'DaemonSet'].include?(o['kind']) && (o.dig('spec', 'type') == 'LoadBalancer' || o.dig('spec', 'template', 'spec', 'hostNetwork')) }, 'Management exporters have no LAN listener')
puts 'Management monitoring isolation, RBAC and delivery contracts: passed'
listener_pem = authentik_runtime.find { |o| o['kind']=='ConfigMap' && o.dig('metadata','name')=='oke-vault-listener-ca' }.dig('data','ca.crt').to_s
check(listener_pem == authentik_values.dig('backup','minio','listenerCa'), 'Rendered listener CA matches backup.minio.listenerCa byte for byte')
check(listener_pem.include?('BEGIN CERTIFICATE') && !listener_pem.include?('PLACEHOLDER') && !listener_pem.include?('PRIVATE KEY'), 'OKE Vault listener CA is a public PEM, not PLACEHOLDER')
blocks = listener_pem.scan(/-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----/m)
certs = blocks.map do |block|
  OpenSSL::X509::Certificate.new(block)
rescue OpenSSL::X509::CertificateError
  nil
end
check(certs.length == 2 && certs.none?(&:nil?) && listener_pem.sub(/-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----\n-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----\n?/m, '').strip.empty?, 'OKE Vault listener CA is exactly two certificates')
cn = ->(name) { name.to_a.assoc('CN')&.at(1) }
check(cn.call(certs[0].subject) == 'DevOops Issuing CA E1' && cn.call(certs[0].issuer) == 'DevOops Root CA R1', 'First certificate is DevOops Issuing CA E1 issued by R1')
check(cn.call(certs[1].subject) == 'DevOops Root CA R1' && cn.call(certs[1].issuer) == 'DevOops Root CA R1', 'Second certificate is self-signed DevOops Root CA R1')
check(certs[0].not_after.utc.strftime('%Y-%m-%d') == '2031-09-05' && certs[1].not_after.utc.strftime('%Y-%m-%d') == '2036-09-03', 'Issuing chain dates are E1 2031-09-05 and R1 2036-09-03')
trust = OpenSSL::X509::Store.new
trust.add_cert(certs[1])
check(trust.verify(certs[0]), 'DevOops Issuing CA E1 verifies under DevOops Root CA R1')
