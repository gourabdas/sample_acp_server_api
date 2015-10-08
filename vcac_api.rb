require 'typhoeus'
require 'json'
require 'crack'
require 'socket'
require 'resolv'

module Vcac

  VCAC_REQUEST_URL_SUFFIX = 'DCACAPI/DcacRequest/Request'
  VCAC_INVENTORY_URL_SUFFIX = 'repository/data/ManagementModelEntities.svc/VirtualMachineExts'
  VCAC_PROPERTIES_URL_SUFFIX = 'Repository/Data/ManagementModelEntities.svc/VirtualMachines(guid\'$GUID\')/VirtualMachineProperties'


  class Machine

    attr_accessor :blueprint_id
    attr_accessor :group_id
    attr_reader :last_response
    attr_reader :machines
    attr_reader :normalized_machines
    attr_accessor :custom_props_string
    attr_accessor :machines_by_id

    def initialize(args)

      @username = args.fetch(:username) { raise 'You must provide :username' }
      @password = args.fetch(:password) { raise 'You must provide :password' }
      @url_prefix = args.fetch(:url) { raise 'You must provide :url' }
      @debug = args.fetch(:debug) { false }
      @timeout = args.fetch(:timeout) { 10 }
      @last_response = {}
      @machines = []
      @machines_by_id = {}
      @normalized_machines = []
      @id_string = nil
      @custom_props_string = ''

      @url = URI.join(@url_prefix, VCAC_REQUEST_URL_SUFFIX).to_s
      @inventory_url = URI.join(@url_prefix, VCAC_INVENTORY_URL_SUFFIX).to_s

    end

    def shutdown(args)
      fire_event args, 'Turn%20Off'
    end

    def start(args)
      fire_event args, 'Turn%20On'
    end

    def expire(args)
      fire_event args, 'Expire'
    end

    def deprovision(args)

      make_id_string(args)

      if @debug
        # Fake a response
        @last_response = {'result' => nil, 'message' => 'Success', 'stacktrace' => nil, 'success' => true}
        return self
      end

      request = Typhoeus::Request.new(
          "#{@url}?#{@id_string}",
          method: :delete,
          timeout: @timeout,
          ssl_verifypeer: false,
          userpwd: "#{@username}:#{@password}")

      request.run

      # request.response.return_code holds TCP type errors like bad host name, etc
      raise request.response.return_code unless request.response.success?

      @last_response = JSON.parse(response_parse(request.response.body.to_s).to_s)

      self
    end

    def provision(args)

      blueprint_id = args.fetch(:blueprint_id) { raise 'You must provide :blueprint_id' }
      group_id = args.fetch(:group_id) { raise 'You must provide :group_id' }

      memory = args.fetch(:memory) { 2048 }
      cpu = args.fetch(:cpu) { 2 }
      disk_size = args.fetch(:disk_size) { 4 }
      custom_props = args.fetch(:custom_props) { {} }
      wait_for_ssh = args.fetch(:wait_for_ssh) { 0 }

      @custom_props_string = props_to_query_string(custom_props)

      if @debug
        fail_if_invalidate_fake_args(args)
        # or
        return self
      end

      request = Typhoeus::Request.new(
          "#{@url}?BlueprintID=#{blueprint_id}&MemoryMb=#{memory}&CpuCount=#{cpu}&GroupId=#{group_id}&DiskSizeGb=#{disk_size}#{@custom_props_string}",
          method: :post,
          ssl_verifypeer: false,
          userpwd: "#{@username}:#{@password}")

      request.run

      # request.response.return_code holds TCP type errors like bad host name, etc
      raise request.response.return_code unless request.response.success?

      # request.response.body holds the return from the API
      @last_response = JSON.parse(response_parse(request.response.body.to_s).to_s)

      raise @last_response['message'] unless @last_response['success']

      @last_response['machine_id'] = @last_response['result']
      @last_response.delete('result')

      machine_id = @last_response['machine_id']

      if wait_for_ssh > 0
        ssh_ready?(wait_for_ssh)
      end

      machine_id

    end

    def get_vm_inventory

      if @debug
        # Fake a response
        @machines = Crack::XML.parse(File.read('doc/virtual_machine_exts.xml'))['feed']['entry']
        normalize_machines
        make_machine_hash_by_id
        return
      end

      request = Typhoeus::Request.new(
          @inventory_url,
          ssl_verifypeer: false,
          method: :get,
          userpwd: "#{@username}:#{@password}")

      request.run

      # request.response.return_code holds TCP type errors like bad host name, etc
      raise request.response.return_code unless request.response.success?

      # XLM Response may contain error message, not actual data
      response_xml = Crack::XML.parse(request.response.body.to_s)

      raise response_xml if response_xml.has_key?('error')

      @machines = response_xml['feed']['entry']
      normalize_machines
      make_machine_hash_by_id
    end

    def make_machine_hash_by_id
      @machines.each do |m|
        @machines_by_id[m['content']['m:properties']['d:VirtualMachineID'].to_s] = m['content']['m:properties']
      end
    end

    def normalized_machines_tsv

      return '' if @normalized_machines.count == 0

      output = ''
      output << "#{@normalized_machines[0].keys.join("\t")}\n"

      @normalized_machines.each do |m|
        m.each do |_, v|
          output << "#{v}\t"
        end
        output << "\n"
      end
      output
    end

    def get_machine_props(machine_id)

      if @debug
        return {}
      end

      request = Typhoeus::Request.new(
          "#{@url_prefix}/Repository/Data/ManagementModelEntities.svc/VirtualMachineExts(guid'#{machine_id}')",
          method: :get,
          ssl_verifypeer: false,
          userpwd: "#{@username}:#{@password}")

      request.run

      # request.response.return_code holds TCP type errors like bad host name, etc
      raise request.response.return_code unless request.response.success?

      raw_props = normalize_machine(Crack::XML.parse(request.response.body.to_s)['entry']) #['content']['m:properties']

      raw_props['custom_props'] = get_custom_props(machine_id)

      raw_props
    end

    private

    def ssh_ready?(seconds=300)

      machine_id = @last_response['machine_id']

      # Get hostname and domain
      props = get_machine_props(machine_id)
      hostname = props[:name]
      domain = props['custom_props']['VirtualMachine.Admin.NameCompletion']

      fqdn = "#{hostname}.#{domain}"

      puts fqdn

      seconds.times do |s|
        begin
          tcp_socket = TCPSocket.new(Resolv.getaddress(fqdn), 22)
          readable = IO.select([tcp_socket], nil, nil, 5)
          return true if readable
        rescue => e
          puts "#{s} sleeping 1... #{e.message}"
          sleep 1
          next
        end
      end
      puts 'ssh not ready, fail.'
      exit 1
    end

    def get_custom_props(machine_id)

      if @debug
        return {}
      end

      suffix = VCAC_PROPERTIES_URL_SUFFIX.gsub('$GUID', machine_id)

      request = Typhoeus::Request.new(
          "#{@url_prefix}/#{suffix}",
          method: :get,
          ssl_verifypeer: false,
          userpwd: "#{@username}:#{@password}")

      request.run

      # request.response.return_code holds TCP type errors like bad host name, etc
      raise request.response.return_code unless request.response.success?

      # request.response.body holds the return from the API
      @last_response = Crack::XML.parse(request.response.body.to_s)['feed']['entry']

      props = {}

      @last_response.each do |r|
        props[r['content']['m:properties']['d:PropertyName']] = r['content']['m:properties']['d:PropertyValue']
      end

      props
    end

    def props_to_query_string(props)
      return '' unless props
      return '' unless props.is_a?(Hash)

      s = '&props='
      props.each do |key, value|
        s << "#{key}=#{value};"
      end

      s.chop!
      s
    end

    # Simulate fake failures for tests
    def fail_if_invalidate_fake_args(args)
      raise 'invalid group id' if args[:group_id] == INVALID_GROUP_ID
      raise 'invalid blueprint id' if args[:blueprint_id] == INVALID_BLUEPRINT_ID
      raise 'invalid url' if args[:url] == INVALID_VCAC_URL
      raise 'invalid password' if @password == INVALID_PASSWORD
      raise 'invalid url' if @url_prefix == INVALID_VCAC_URL

      @last_response = {'message' => 'Success', 'stacktrace' => nil, 'success' => true, 'machine_id' => '02800475-14ec-4a7e-8680-c0e4c16119d6'}

    end

    def normalize_machine(m)
      normal = {}
      normal[:id] = m['content']['m:properties']['d:VirtualMachineID'].to_s
      normal[:name] = m['content']['m:properties']['d:MachineName'].to_s
      normal[:status] = m['content']['m:properties']['d:Status'].to_s
      normal[:cpu_count] = m['content']['m:properties']['d:VMCPUs'].to_s
      normal[:ram] = m['content']['m:properties']['d:VMTotalMemoryGB'].to_s.to_i
      normal[:storage] = m['content']['m:properties']['d:VMTotalStorageGB'].to_s.to_i
      normal[:type] = m['content']['m:properties']['d:MachineType'].to_s
      normal[:host_name] = m['content']['m:properties']['d:HostName'].to_s
      normal[:end_point_name] = m['content']['m:properties']['d:EndpointName'].to_s
      normal[:end_point_interface_type] = m['content']['m:properties']['d:EndpointInterfaceType'].to_s
      normal[:storage_path_summary] = m['content']['m:properties']['d:StoragePathsSummary'].to_s

      if m['content']['m:properties']['d:BlueprintName'].is_a?(Hash)
        normal[:blueprint_name] = nil
      else
        normal[:blueprint_name] = m['content']['m:properties']['d:BlueprintName'].to_s
      end

      if  m['content']['m:properties']['d:ReservationName'].is_a?(Hash)
        normal[:reservation_name] = nil
      else
        normal[:reservation_name] = m['content']['m:properties']['d:ReservationName'].to_s
      end

      if  m['content']['m:properties']['d:UserName'].is_a?(Hash)
        normal[:user_name] = nil
      else
        normal[:user_name] = m['content']['m:properties']['d:UserName'].to_s
      end

      if  m['content']['m:properties']['d:CostProfileName'].is_a?(Hash)
        normal[:cost_profile_name] = nil
      else
        normal[:cost_profile_name] = m['content']['m:properties']['d:CostProfileName'].to_s
      end

      normal
    end

    def normalize_machines

      @machines.each do |m|
        @normalized_machines << normalize_machine(m)
      end
    end

    def fire_event(args, event)
      make_id_string(args)

      if @debug
        # Fake a response
        @last_response = {'result' => nil, 'message' => 'Success', 'stacktrace' => nil, 'success' => true}
        return self
      end

      request = Typhoeus::Request.new(
          "#{@url}?#{@id_string}&EventName=#{event}",
          ssl_verifypeer: false,
          method: :put,
          timeout: @timeout,
          userpwd: "#{@username}:#{@password}")

      request.run

      # request.response.return_code holds TCP type errors like bad host name, etc
      raise request.response.return_code unless request.response.success?

      @last_response = JSON.parse(response_parse(request.response.body.to_s).to_s)

      self

    end

    def make_id_string(args)

      @machine_name = args.fetch(:machine_name) { nil }
      @machine_id = args.fetch(:machine_id) { nil }

      if @machine_id
        @id_string = "MachineId=#{@machine_id}"
      elsif @machine_name
        @id_string = "MachineName=#{@machine_id}"
      else
        raise ('You must provide either :machine_name or :machine_id')
      end

    end

    def response_parse(response)
      /{.+}/.match(response)
    end

  end
end