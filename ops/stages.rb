module Ceremony
  MESH = %w[vault pki certificates istio qualification enrollment authentik].freeze
  CLUSTER = %w[secrets bgp].freeze
  raise 'cluster stages must stay off the mesh predecessor chain' if (MESH & CLUSTER).any?
  PROMOTABLE = (MESH + CLUSTER).freeze
  PROMOTE_PR = (MESH - %w[authentik] + CLUSTER).freeze
end
