#!/usr/bin/env ruby
# Metasploit Dashboard - Local Web Interface
# Usage: bundle exec ruby tools/dashboard/app.rb
# Then visit http://localhost:4567

require 'sinatra'
require 'json'
require 'open3'
require 'securerandom'

set :bind, '127.0.0.1'
set :port, 4567
set :views, File.join(File.dirname(__FILE__), 'views')
set :public_folder, File.join(File.dirname(__FILE__), 'public')

MSF_ROOT = File.expand_path('../../..', __FILE__)

# Store scan results in memory
RESULTS = {}

helpers do
  def h(text)
    Rack::Utils.escape_html(text.to_s)
  end

  def msf_exec(resource_script)
    cmd = "bundle exec ruby #{MSF_ROOT}/msfconsole -q -r #{resource_script} 2>&1"
    stdout, status = Open3.capture2(cmd, chdir: MSF_ROOT)
    stdout
  end
end

# ─── Dashboard ────────────────────────────────────────────────────
get '/' do
  erb :dashboard
end

# ─── Nmap Scanner ─────────────────────────────────────────────────
post '/scan/nmap' do
  content_type :json
  target = params[:target].to_s.strip
  scan_type = params[:scan_type].to_s.strip
  ports = params[:ports].to_s.strip

  return { error: 'Target is required' }.to_json if target.empty?

  # Build nmap command based on scan type
  nmap_flags = case scan_type
               when 'quick'    then '-T4 -F'
               when 'service'  then '-sV -sC'
               when 'full'     then '-sV -sC -A -T4 -p-'
               when 'udp'      then '-sU --top-ports 100'
               when 'stealth'  then '-sS -T2'
               else '-sV'
               end

  nmap_flags += " -p #{ports}" unless ports.empty? || scan_type == 'full'

  id = SecureRandom.hex(8)
  RESULTS[id] = { status: 'running', output: '', tool: 'nmap', target: target, started: Time.now.to_s }

  Thread.new do
    begin
      cmd = "nmap #{nmap_flags} #{target}"
      RESULTS[id][:command] = cmd
      stdout, _status = Open3.capture2(cmd, chdir: MSF_ROOT)
      RESULTS[id][:output] = stdout
      RESULTS[id][:status] = 'complete'
    rescue => e
      RESULTS[id][:output] = "Error: #{e.message}"
      RESULTS[id][:status] = 'error'
    end
  end

  { id: id, status: 'running' }.to_json
end

# ─── MSF Auxiliary Scanner ────────────────────────────────────────
post '/scan/msf' do
  content_type :json
  target = params[:target].to_s.strip
  mod = params[:module].to_s.strip

  return { error: 'Target and module are required' }.to_json if target.empty? || mod.empty?

  id = SecureRandom.hex(8)
  RESULTS[id] = { status: 'running', output: '', tool: 'metasploit', target: target, started: Time.now.to_s }

  Thread.new do
    begin
      # Create a resource script
      rc_path = "/tmp/msf_scan_#{id}.rc"
      File.write(rc_path, <<~RC)
        use #{mod}
        set RHOSTS #{target}
        run
        exit
      RC
      RESULTS[id][:command] = "msfconsole -r #{rc_path}"
      output = msf_exec(rc_path)
      RESULTS[id][:output] = output
      RESULTS[id][:status] = 'complete'
      File.delete(rc_path) if File.exist?(rc_path)
    rescue => e
      RESULTS[id][:output] = "Error: #{e.message}"
      RESULTS[id][:status] = 'error'
    end
  end

  { id: id, status: 'running' }.to_json
end

# ─── msfvenom Payload Generator ──────────────────────────────────
post '/generate/payload' do
  content_type :json
  payload = params[:payload].to_s.strip
  format = params[:format].to_s.strip
  lhost = params[:lhost].to_s.strip
  lport = params[:lport].to_s.strip

  return { error: 'Payload and format are required' }.to_json if payload.empty? || format.empty?

  id = SecureRandom.hex(8)
  outfile = "/tmp/msf_payload_#{id}.#{format}"
  RESULTS[id] = { status: 'running', output: '', tool: 'msfvenom', started: Time.now.to_s }

  Thread.new do
    begin
      cmd = "bundle exec ruby #{MSF_ROOT}/msfvenom -p #{payload}"
      cmd += " LHOST=#{lhost}" unless lhost.empty?
      cmd += " LPORT=#{lport}" unless lport.empty?
      cmd += " -f #{format} -o #{outfile}"
      RESULTS[id][:command] = cmd
      stdout, _status = Open3.capture2(cmd, chdir: MSF_ROOT)
      RESULTS[id][:output] = stdout
      RESULTS[id][:file] = outfile if File.exist?(outfile)
      RESULTS[id][:status] = 'complete'
    rescue => e
      RESULTS[id][:output] = "Error: #{e.message}"
      RESULTS[id][:status] = 'error'
    end
  end

  { id: id, status: 'running' }.to_json
end

# ─── Database Queries ─────────────────────────────────────────────
post '/db/query' do
  content_type :json
  query_type = params[:query_type].to_s.strip

  rc_cmd = case query_type
           when 'hosts'    then 'hosts'
           when 'services' then 'services'
           when 'vulns'    then 'vulns'
           when 'creds'    then 'creds'
           when 'loot'     then 'loot'
           else 'hosts'
           end

  id = SecureRandom.hex(8)
  RESULTS[id] = { status: 'running', output: '', tool: 'database', started: Time.now.to_s }

  Thread.new do
    begin
      rc_path = "/tmp/msf_db_#{id}.rc"
      File.write(rc_path, "#{rc_cmd}\nexit\n")
      RESULTS[id][:command] = rc_cmd
      output = msf_exec(rc_path)
      RESULTS[id][:output] = output
      RESULTS[id][:status] = 'complete'
      File.delete(rc_path) if File.exist?(rc_path)
    rescue => e
      RESULTS[id][:output] = "Error: #{e.message}"
      RESULTS[id][:status] = 'error'
    end
  end

  { id: id, status: 'running' }.to_json
end

# ─── Module Search ────────────────────────────────────────────────
post '/search' do
  content_type :json
  query = params[:query].to_s.strip
  return { error: 'Search query is required' }.to_json if query.empty?

  id = SecureRandom.hex(8)
  RESULTS[id] = { status: 'running', output: '', tool: 'search', started: Time.now.to_s }

  Thread.new do
    begin
      rc_path = "/tmp/msf_search_#{id}.rc"
      File.write(rc_path, "search #{query}\nexit\n")
      RESULTS[id][:command] = "search #{query}"
      output = msf_exec(rc_path)
      RESULTS[id][:output] = output
      RESULTS[id][:status] = 'complete'
      File.delete(rc_path) if File.exist?(rc_path)
    rescue => e
      RESULTS[id][:output] = "Error: #{e.message}"
      RESULTS[id][:status] = 'error'
    end
  end

  { id: id, status: 'running' }.to_json
end

# ─── Poll Results ─────────────────────────────────────────────────
get '/results/:id' do
  content_type :json
  result = RESULTS[params[:id]]
  return { error: 'Not found' }.to_json unless result
  result.to_json
end

# ─── List All Results ─────────────────────────────────────────────
get '/results' do
  content_type :json
  RESULTS.map { |id, r| { id: id, tool: r[:tool], target: r[:target], status: r[:status], started: r[:started] } }.to_json
end
