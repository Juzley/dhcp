use Mix.Config

config :dhcp, udp_impl: Dhcp.Test.GenUDP
config :dhcp, timer_impl: Dhcp.Test.Timer
