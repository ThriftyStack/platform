{{- define "thrifty-authentik.serverPodAffinity" -}}
podAffinity:
  requiredDuringSchedulingIgnoredDuringExecution:
    - labelSelector:
        matchLabels:
          app.kubernetes.io/name: authentik
          app.kubernetes.io/instance: {{ .Release.Name }}
          app.kubernetes.io/component: server
      topologyKey: kubernetes.io/hostname
{{- end }}

{{- define "thrifty-authentik.backupPostgresEnv" -}}
- name: PGHOST
  valueFrom:
    secretKeyRef:
      name: {{ .Values.backup.postgres.secretName }}
      key: {{ .Values.backup.postgres.hostKey }}
- name: PGUSER
  valueFrom:
    secretKeyRef:
      name: {{ .Values.backup.postgres.secretName }}
      key: {{ .Values.backup.postgres.userKey }}
- name: PGDATABASE
  valueFrom:
    secretKeyRef:
      name: {{ .Values.backup.postgres.secretName }}
      key: {{ .Values.backup.postgres.databaseKey }}
- name: PGPASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.backup.postgres.secretName }}
      key: {{ .Values.backup.postgres.passwordKey }}
- name: PGSSLMODE
  value: disable
- name: AGE_RECIPIENT
  value: {{ .Values.backup.ageRecipient | quote }}
- name: AUTHENTIK_VERSION
  value: {{ .Chart.AppVersion | quote }}
- name: POSTGRESQL_MAJOR
  value: "17"
- name: BACKUP_PREFIX
  value: {{ .Values.backup.minio.prefix | quote }}
{{- end }}

{{- define "thrifty-authentik.backupAwsEnv" -}}
- name: AWS_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef:
      name: {{ .Values.backup.minio.secretName }}
      key: {{ .Values.backup.minio.accessKeyProperty }}
- name: AWS_SECRET_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.backup.minio.secretName }}
      key: {{ .Values.backup.minio.secretKeyProperty }}
- name: AWS_DEFAULT_REGION
  value: {{ .Values.backup.minio.region | quote }}
- name: ENDPOINT
  value: {{ .Values.backup.minio.endpoint | quote }}
- name: BUCKET
  value: {{ .Values.backup.minio.bucket | quote }}
- name: PREFIX
  value: {{ .Values.backup.minio.prefix | quote }}
{{- end }}

{{- define "thrifty-authentik.ageEncrypt" -}}
- name: encrypt-{{ .file | replace "." "-" }}
  image: {{ .root.Values.backup.images.age | quote }}
  imagePullPolicy: IfNotPresent
  command: ["/usr/local/bin/age"]
  args:
    - --recipient
    - {{ .root.Values.backup.ageRecipient | quote }}
    - --output
    - /work/plain/{{ .file }}.age
    - /work/plain/{{ .file }}
  resources:
    requests:
      cpu: 20m
      memory: 32Mi
    limits:
      memory: 128Mi
  volumeMounts:
    - name: work
      mountPath: /work
{{- end }}
