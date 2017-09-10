use Mix.Config

config :dhcp, server_address: {192, 168, 0, 100}
config :dhcp, gateway_address: {192, 168, 0, 1}
config :dhcp, dns_address: {192, 168, 0, 1}
config :dhcp, subnet_mask: {255, 255, 255, 0}
config :dhcp, min_address: {192, 168, 0, 101}
config :dhcp, max_address: {192, 168, 0, 255}
config :dhcp, max_lease: 86400
