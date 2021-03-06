require "faye/websocket"
require "packetfu"
require "json"
require "socket"
include PacketFu

TOKEN = File.open("token").read.gsub(/\n/, '')
URL = File.open("url").read.gsub(/\n/, '')
SERVER_PATH = "#{URL}?token=#{TOKEN}"
$opened = false
$ws = nil

def send_server(p)
  p "sending?"
  if $opened
    p "sending"
    msg = {command: "message",
           data: {data: p.to_json}.to_json,
           identifier: {channel: "CaptureChannel"}.to_json}
    p $ws.send(msg.to_json)
  end
end

def get_capture_and_send(iface)
  cap = Capture.new(:iface=>iface, :start=>true)
  pkts = []
  cap.stream.each do |pkt|
    $ws.ping 'living..' do
      # fires when pong is received
    end
    begin
      if TCPPacket.can_parse?(pkt)
        tcp_packet = TCPPacket.parse(pkt)
        src_mac = EthHeader.str2mac(tcp_packet.eth_src).to_s
        dst_mac = EthHeader.str2mac(tcp_packet.eth_dst).to_s
        src_ip = IPHeader.octet_array(tcp_packet.ip_src).join('.')
        dst_ip = IPHeader.octet_array(tcp_packet.ip_dst).join('.')
        src_port = tcp_packet.tcp_src.to_s
        dst_port = tcp_packet.tcp_dst.to_s
        # p "tcp => (#{src_mac} - #{dst_mac}) => (#{src_ip} - #{dst_ip}) => (#{src_port} - #{dst_port})"
        src = {smac: src_mac, sip: src_ip, sport: src_port}
        dst = {dmac: dst_mac, dip: dst_ip, dport: dst_port}
        p = {src: src, dst: dst, iface_name: iface, host: Socket.gethostname,
             content: pkt.force_encoding("ISO-8859-1").encode("UTF-8"),
             type: "tcp"}
        # send_server(pkt)
        pkts << p
      elsif UDPPacket.can_parse?(pkt)
        udp_packet = UDPPacket.parse(pkt)
        unless udp_packet.ip_src.nil?
          src_mac = EthHeader.str2mac(udp_packet.eth_src).to_s
          dst_mac = EthHeader.str2mac(udp_packet.eth_dst).to_s
          src_ip = IPHeader.octet_array(udp_packet.ip_src).join('.')
          dst_ip = IPHeader.octet_array(udp_packet.ip_dst).join('.')
          src_port = udp_packet.udp_src.to_s
          dst_port = udp_packet.udp_dst.to_s
          # p "udp => (#{src_mac} - #{dst_mac}) => (#{src_ip} - #{dst_ip}) => (#{src_port} - #{dst_port})"
          src = {smac: src_mac, sip: src_ip, sport: src_port}
          dst = {dmac: dst_mac, dip: dst_ip, dport: dst_port}
          p = {src: src, dst: dst, iface_name: iface, host: Socket.gethostname,
               content: pkt.force_encoding("ISO-8859-1").encode("UTF-8"),
               type: "udp"}
          # send_server(pkt)
          pkts << p
        end
      end
    rescue => e
      p "failed"
      p e
    ensure
      p " % 100" if pkts.size % 100 == 0
      if pkts.size > 300
        p "send"
        send_server(pkts)
        pkts = []
      end
    end
  end
end

# get interface who have ipv4
ifaces = Socket.getifaddrs.select{|x| x.name != "lo" && x.addr.ipv4?}

threads = []

threads << Thread.new{
  EM.run {
    $ws = Faye::WebSocket::Client.new(SERVER_PATH, nil)
    $ws.on :open do |event|
      $opened = true
      p [:open]
      cmd = {command: "subscribe", identifier: {channel: "CaptureChannel"}.to_json}
      $ws.send(JSON.generate(cmd))
    end

    $ws.on :close do |event|
      p [:close, event.code, event.reason]
      $ws = nil
    end
  }
}
ifaces.each do |i|
  threads << Thread.new{ get_capture_and_send(i.name)}
end
threads.each{|t| t.join}
