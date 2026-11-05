require 'yaml'
docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
def check(condition, message)
  raise message unless condition
end
by_kind = docs.group_by { |d| d.fetch('kind') }
check(by_kind.keys.sort == %w[ConfigMap Namespace NetworkPolicy PersistentVolumeClaim Service StatefulSet].sort, 'Unexpected resources')
check(by_kind['Service'].size == 2, 'Unexpected service count')
service = by_kind['Service'].find { |s| s['spec']['type'] == 'NodePort' }
check(service['spec']['ports'] == [{'name'=>'orport','protocol'=>'TCP','port'=>9001,'targetPort'=>'orport','nodePort'=>30001}], 'Unexpected public ports')
sts = by_kind['StatefulSet'].first
check(sts['spec']['replicas'] == 1, 'More than one identity instance')
pod = sts['spec']['template']['spec']
check(!pod['hostNetwork'] && !pod['hostPID'] && !pod['hostIPC'], 'Host namespace')
check(pod['automountServiceAccountToken'] == false, 'API credential mounted')
check(pod['securityContext']['runAsNonRoot'] && pod['securityContext']['seccompProfile']['type'] == 'RuntimeDefault', 'Pod hardening missing')
check(pod['volumes'].none? { |v| v.key?('hostPath') }, 'Host path mounted')
container = pod['containers'].fetch(0)
check(pod['containers'].size == 1, 'Unexpected sidecar')
check(container['image'].match?(/@sha256:[a-f0-9]{64}$/), 'Mutable image')
security = container['securityContext']
check(security['readOnlyRootFilesystem'] && !security['allowPrivilegeEscalation'] && security['capabilities']['drop'] == ['ALL'], 'Container hardening missing')
check(container['ports'].map { |p| p['containerPort'] } == [9001], 'Unexpected container ports')
%w[startupProbe readinessProbe livenessProbe].each { |probe| check(container.key?(probe), "Missing #{probe}") }
check(pod['volumes'].any? { |v| v.dig('persistentVolumeClaim','claimName') == 'tor-relay-data' }, 'Identity not persistent')
check(by_kind['PersistentVolumeClaim'].first.dig('metadata','annotations','helm.sh/resource-policy') == 'keep', 'PVC not retained')
check(by_kind['Namespace'].first.dig('metadata','labels','pod-security.kubernetes.io/enforce') == 'restricted', 'Namespace not restricted')
policy = by_kind['NetworkPolicy'].first['spec']
check(policy['policyTypes'].sort == %w[Egress Ingress], 'Policy missing')
check(policy['ingress'] == [{'ports'=>[{'protocol'=>'TCP','port'=>9001}]}], 'Extra ingress')
File.write(ARGV.fetch(1), by_kind['ConfigMap'].first.fetch('data').fetch('torrc'))
puts 'Manifest security assertions passed'
