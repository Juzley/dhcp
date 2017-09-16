use Mix.Config

config :dhcp, udp_impl: Dhcp.Test.GenUDP
config :dhcp, timer_impl: Dhcp.Test.Timer
config :dhcp, timex_impl: Dhcp.Test.Timex
config :dhcp, server_address: {192, 168, 0, 2}
config :dhcp, gateway_address: {192, 168, 0, 1}
config :dhcp, dns_address: {192, 168, 0, 1}
config :dhcp, subnet_mask: {255, 255, 255, 0}
config :dhcp, min_address: {192, 168, 0, 3}
config :dhcp, max_address: {192, 168, 0, 5}
config :dhcp, max_lease: 86400
