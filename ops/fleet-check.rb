#!/usr/bin/env ruby
# Loaded by check.rb: real Helm/Sprig rendering and the pinned Argo CRD, no live API.
require 'tmpdir'
all = render(HELM,'template','management',CHART,*cluster_profile('management'))
fleet = all.find { |o| o['kind']=='ApplicationSet' }
check(fleet && fleet.dig('metadata','name')=='spokes', 'Hub must own the spoke ApplicationSet')
check(fleet.dig('spec','goTemplateOptions')==['missingkey=error'], 'Missing inventory fields must fail closed')
check(fleet.dig('spec','syncPolicy')=={'applicationsSync'=>'create-update','preserveResourcesOnDeletion'=>true}, 'Preserve generated Applications and workloads')
check(!fleet.dig('metadata','finalizers') && !fleet.dig('spec','template','metadata','finalizers'), 'No destructive cascade finalizers')
check(fleet.dig('spec','template','spec','syncPolicy','automated','prune')==false, 'Spoke infrastructure must not auto-prune')
check(fleet.dig('spec','template','spec','destination')=={'server'=>'https://kubernetes.default.svc','namespace'=>'argocd'}, 'Spoke roots are always owned by the hub')
children=fleet.dig('spec','generators')[0].dig('matrix','generators')
check(children.length==2 && children[0]['git'] && children[1]['clusters'], 'Use native inventory x registered-cluster matrix')
check(children[0].dig('git','files').include?({'path'=>'clusters/management/cluster.yaml','exclude'=>true}), 'Never regenerate the management root')
selector=children[1].dig('clusters','selector')
%w[enabled prepared].each do |key|
 check(selector['matchExpressions'].include?({'key'=>"thriftystack.io/#{key}",'operator'=>'In','values'=>['true']}), 'Both profile and registry must affirm readiness')
end
check(selector['matchLabels']['thriftystack.io/role']=='spoke', 'Local/default clusters must not be implicitly enrolled')
artifact=JSON.parse(File.read("#{ROOT}/dependencies.lock.json"))['validationCharts'].find { |a| a['chart']=='argo-cd' }
crd=render(HELM,'template','argo-schema',"#{CACHE}/#{artifact['archive']}",'--show-only','templates/crds/crd-applicationset.yaml').first
schema=crd['spec']['versions'].find { |v| v['name']=='v1alpha1' }['schema']['openAPIV3Schema']['properties']['spec']
validate(fleet['spec'],schema,'ApplicationSet/spokes')
# Reuse Helm's real Go-template/Sprig engine on the exact emitted AppSet template strings.
Dir.mktmpdir('fleet-template') do |directory|
 File.write("#{directory}/Chart.yaml",{'apiVersion'=>'v2','name'=>'fleet-check','version'=>'1.0.0'}.to_yaml)
 Dir.mkdir("#{directory}/templates")
 File.write("#{directory}/templates/root.yaml", <<~'HELM')
 {{- define "evaluate" -}}
 {{- if kindIs "map" .value -}}
 {{- $out := dict -}}{{- range $k, $v := .value -}}{{- $_ := set $out $k (include "evaluate" (dict "value" $v "context" $.context) | fromJson).value -}}{{- end -}}{{- dict "value" $out | toJson -}}
 {{- else if kindIs "slice" .value -}}
 {{- $out := list -}}{{- range .value -}}{{- $out = append $out (include "evaluate" (dict "value" . "context" $.context) | fromJson).value -}}{{- end -}}{{- dict "value" $out | toJson -}}
 {{- else if kindIs "string" .value -}}{{- dict "value" (tpl .value .context) | toJson -}}
 {{- else -}}{{- dict "value" .value | toJson -}}{{- end -}}
 {{- end -}}
 {{- $context := deepCopy .Values.parameters -}}
 {{- $_ := set $context "Template" .Template -}}
 {{ (include "evaluate" (dict "value" (.Files.Get "object.json" | fromJson) "context" $context) | fromJson).value | toYaml }}
 HELM
 def object_file(directory, object)
   File.write("#{directory}/object.json", JSON.generate(object))
 end
 object_file(directory, {'apiVersion'=>'argoproj.io/v1alpha1','kind'=>'Application','metadata'=>fleet['spec']['template']['metadata'],'spec'=>fleet['spec']['template']['spec']})
 profile=YAML.safe_load(File.read("#{ROOT}/clusters/oci/cluster.yaml"))['cluster'].merge('server'=>'https://oci-api.invalid:6443','enabled'=>true,'prepared'=>true,'environment'=>'staging')
 params={'cluster'=>profile,'server'=>profile['server']}
 File.write("#{directory}/values.yaml",{'parameters'=>params}.to_yaml)
 app=render(HELM,'template','spoke',directory).first
 check(app.dig('metadata','name')=='oci' && app.dig('spec','project')=='oci','Generated spoke identity/project')
 check(app.dig('spec','source','path')=='charts/cluster-apps','Spoke roots render the cluster-apps chart')
 check(app.dig('spec','source','helm','valueFiles')==['../../clusters/oci/values.yaml','../../clusters/oci/cluster.yaml'],'Cluster-specific promotions and identities')
 check(app.dig('spec','source','helm','parameters')[0]['value']==profile['server'],'Registered API is passed to workload children')
 # Render the exact selector through the same native Go template engine.
 object_file(directory, {'apiVersion'=>'v1','kind'=>'ConfigMap','metadata'=>{'name'=>'selector'},'data'=>selector['matchLabels']})
 expected=render(HELM,'template','selector',directory).first['data']
 check(expected['thriftystack.io/cluster-id']=='oci' && expected['thriftystack.io/environment']=='staging' && expected['thriftystack.io/cloud']=='oci','ID/environment/cloud registry selectors')
 params['cluster']['enabled']=false
 File.write("#{directory}/values.yaml",{'parameters'=>params}.to_yaml)
 disabled=render(HELM,'template','selector',directory).first['data']
 check(disabled['thriftystack.io/enabled']=='false','Disabled inventory cannot match the required enabled=true registry selector')
 params['cluster']['enabled']=true; params['server']='https://wrong-api.invalid:6443'
 File.write("#{directory}/values.yaml",{'parameters'=>params}.to_yaml)
 object_file(directory, {'apiVersion'=>'v1','kind'=>'ConfigMap','metadata'=>{'name'=>fleet['spec']['template']['metadata']['name']}})
 _, _, status=Open3.capture3(HELM,'template','mismatch',directory)
 check(!status.success?, 'Registered/profile API mismatch must reject root generation')
end
check(all.none? { |o| o['kind']=='AppProject' && o.dig('metadata','name')=='oci' }, 'No OCI access grant by default')
projects=render(HELM,'template','approved',CHART,*cluster_profile('management'),'--set','spokeProjects.oci.enabled=true','--set','spokeProjects.oci.server=https://oci-api.invalid:6443','--set','spokeProjects.oci.namespaces={cert-manager,istio-system,mesh-test}')
project=projects.find { |o| o['kind']=='AppProject' }
check(project.dig('spec','sourceRepos')==[YAML.safe_load(File.read("#{ROOT}/clusters/management/values.yaml")).dig('fleet','repository')], 'Spoke projects source only the platform repository')
check(project.dig('spec','clusterResourceWhitelist').none? { |r| r.values.include?('*') }, 'No wildcard spoke cluster privileges')
check(project.dig('spec','destinations').all? { |d| d['server']=='https://oci-api.invalid:6443' || d=={'server'=>'https://kubernetes.default.svc','namespace'=>'argocd'} }, 'Explicit spoke destination policy')
%w[spokeProjects.bad-.enabled=true spokeProjects.oci.namespaces={*} spokeProjects.oci.server=https://*].each do |invalid|
 _, _, status=Open3.capture3(HELM,'template','invalid-project',CHART,*cluster_profile('management'),'--set','spokeProjects.oci.enabled=true','--set','spokeProjects.oci.server=https://oci-api.invalid:6443','--set','spokeProjects.oci.namespaces={mesh-test}','--set',invalid)
 check(!status.success?, 'Reject invalid IDs or wildcard destination approval')
end
fleet_values=YAML.safe_load(File.read("#{ROOT}/clusters/management/values.yaml"))['fleet']
check(fleet_values['applicationsRepository'] && fleet_values['applicationsRepository']!=fleet_values['repository'], 'Platform and applications repositories must be distinct')
check(all.none? { |o| o['kind']=='AppProject' && o.dig('metadata','name')=='demo-app' }, 'No workload access grant by default')
workload=render(HELM,'template','workload',CHART,*cluster_profile('management'),'--set','workloadProjects.demo-app.enabled=true','--set','workloadProjects.demo-app.server=https://kubernetes.default.svc','--set','workloadProjects.demo-app.namespaces={demo}')
workload_project=workload.find { |o| o['kind']=='AppProject' && o.dig('metadata','name')=='demo-app' }
check(workload_project.dig('spec','sourceRepos')==[fleet_values['applicationsRepository']], 'Workload projects source only the applications repository')
check(workload_project.dig('spec','clusterResourceWhitelist')==[], 'Workload projects grant no cluster-scoped resources')
check(workload_project.dig('spec','destinations').none? { |d| d['namespace']=='argocd' }, 'Workload projects must not destination the hub argocd namespace')
[['workloadProjects.demo-app.namespaces={argocd}','argocd namespace'],['workloadProjects.demo-app.server=https://*','wildcard API'],['fleet.applicationsRepository=https://github.com/sudoceohq/argocd.git','same as platform repo']].each do |flag, reason|
 _, _, status=Open3.capture3(HELM,'template','invalid-workload',CHART,*cluster_profile('management'),'--set','workloadProjects.demo-app.enabled=true','--set','workloadProjects.demo-app.server=https://kubernetes.default.svc','--set','workloadProjects.demo-app.namespaces={demo}','--set',flag)
 check(!status.success?, "Reject workload approval: #{reason}")
end
profiles=Dir["#{ROOT}/clusters/*/cluster.yaml"].map { |p| [File.basename(File.dirname(p)),YAML.safe_load(File.read(p))['cluster']] }
check(profiles.all? { |id,c| id==c['id'] }, 'Inventory folder and cluster ID must agree')
check(profiles.map { |_,c| c['id'] }.uniq.length==profiles.length, 'Unique cluster IDs')
check(profiles.map { |_,c| c['trustDomain'] }.uniq.length==profiles.length, 'Separate cluster trust domains')
check(!Dir.exist?("#{ROOT}/applications"), 'Workload charts must not live in the platform repository')

puts 'Hub/spoke ApplicationSet schema, generation, isolation and deletion contracts: passed'
