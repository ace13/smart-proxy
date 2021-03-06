require 'test_helper'
require "dhcp_common/subnet"
require "dhcp_common/record"
require "dhcp_common/record/lease"
require "dhcp_common/record/reservation"
require 'dhcpsapi'
require 'dhcp_native_ms/dhcp_native_ms'
require 'dhcp_native_ms/dhcp_native_ms_main'
require 'dhcp/sparc_attrs'

class DHCPServerMicrosoftTest < Test::Unit::TestCase
  def setup
    @dhcpsapi = Object.new
    @network = '192.168.42.0'
    @netmask = '255.255.255.0'
    @server = Proxy::DHCP::NativeMS::Provider.new(@dhcpsapi, ["#{@network}/#{@netmask}"], false)
    @option_values = [{:option_id => 6, :value => [{:option_type => 4, :element => '192.168.42.1'}]},
                      {:option_id => 15, :value => [{:option_type => 5, :element => 'test.com'}]}]
  end

  def test_should_return_subnet
    @dhcpsapi.expects(:list_subnets).returns([{:subnet_address => @network, :subnet_mask => @netmask}])
    @dhcpsapi.expects(:list_subnet_option_values).returns([])

    subnets = @server.subnets

    assert_equal 1, subnets.size
    assert_equal @network, subnets.first.network
    assert_equal @netmask, subnets.first.netmask
  end

  def test_should_skip_non_managed_subnets
    @dhcpsapi.expects(:list_subnets).returns([{:subnet_address => '192.168.43.0', :subnet_mask => '255.255.255.0'}])
    assert @server.subnets.empty?
  end

  def test_should_return_subnet_with_options
    @dhcpsapi.expects(:list_subnets).returns([{:subnet_address => @network, :subnet_mask => @netmask}])
    @dhcpsapi.expects(:list_subnet_option_values).returns(@option_values)

    subnets = @server.subnets

    assert_equal 1, subnets.size
    assert_equal({:domain_name_servers => ['192.168.42.1'], :domain_name => 'test.com'}, subnets.first.options)
  end

  def test_should_return_all_hosts
    @dhcpsapi.expects(:list_subnet_elements).with(@network, anything).returns([{:element => {:reserved_ip_address => '192.168.42.10'}}])
    @dhcpsapi.expects(:list_clients_2008).with(@network).returns([
      {:client_ip_address => '192.168.42.10', :subnet_mask => @netmask, :client_hardware_address => '00:01:02:03:04:05', :client_name => 'test', :client_lease_expires => nil},
      {:client_ip_address => '192.168.42.11', :subnet_mask => @netmask, :client_hardware_address => '00:01:02:03:04:06', :client_name => 'test-2', :client_lease_expires => Time.now + 120}])

    hosts = @server.all_hosts(@network)

    assert_equal 1, hosts.size
    assert_equal ::Proxy::DHCP::Reservation.new(:subnet => ::Proxy::DHCP::Subnet.new(@network, @netmask),
                                                :ip => '192.168.42.10',
                                                :mac => '00:01:02:03:04:05',
                                                :name => 'test',
                                                :hostname => 'test',
                                                :deleteable => true), hosts.first
  end

  def test_should_return_all_leases
    lease_expires = Time.now + 120
    @dhcpsapi.expects(:list_subnet_elements).with(@network, anything).returns([{:element => {:reserved_ip_address => '192.168.42.10'}}])
    @dhcpsapi.expects(:list_clients_2008).with(@network).returns([
      {:client_ip_address => '192.168.42.10', :subnet_mask => @netmask, :client_hardware_address => '00:01:02:03:04:05', :client_name => 'test', :client_lease_expires => nil},
      {:client_ip_address => '192.168.42.11', :subnet_mask => @netmask, :client_hardware_address => '00:01:02:03:04:06', :client_name => 'test-2', :client_lease_expires => lease_expires}])

    leases = @server.all_leases(@network)

    assert_equal 1, leases.size
    assert_equal ::Proxy::DHCP::Lease.new(:subnet => ::Proxy::DHCP::Subnet.new(@network, @netmask),
                                    :ip => '192.168.42.11',
                                    :mac => '00:01:02:03:04:06',
                                    :name => 'test-2',
                                    :ends => lease_expires), leases.first
  end

  def test_should_return_free_ip_address
    @dhcpsapi.expects(:get_client_by_mac_address).raises(RuntimeError)
    @dhcpsapi.expects(:get_free_ip_address).with(@network, nil, nil).returns(['192.168.42.20'])
    assert_equal '192.168.42.20', @server.unused_ip(::Proxy::DHCP::Subnet.new(@network, @netmask), '00:01:02:03:04:05', nil, nil)
  end

  def test_unused_ip_address_for_known_mac_address
    @dhcpsapi.expects(:get_client_by_mac_address).with(@network, '00:01:02:03:04:05').returns(:client_ip_address => '192.168.42.20')
    assert_equal '192.168.42.20', @server.unused_ip(::Proxy::DHCP::Subnet.new(@network, @netmask), '00:01:02:03:04:05', nil, nil)
  end

  def test_find_record_should_return_reservation_by_ip_address
    client_ip = '192.168.42.10'
    @dhcpsapi.expects(:list_subnet_elements).with(@network, anything).returns([{:element => {:reserved_ip_address => client_ip}}])
    @dhcpsapi.expects(:get_client_by_ip_address).with(client_ip).returns(
        :client_ip_address => client_ip, :subnet_mask => @netmask, :client_hardware_address => '00:01:02:03:04:05', :client_name => 'test', :client_lease_expires => nil
    )
    @dhcpsapi.expects(:list_reserved_option_values).with(client_ip, @network).returns(@option_values)

    record = @server.find_record(@network, client_ip)
    assert_equal ::Proxy::DHCP::Reservation.new(:subnet => ::Proxy::DHCP::Subnet.new(@network, @netmask),
                                                :ip => client_ip,
                                                :mac => '00:01:02:03:04:05',
                                                :name => 'test',
                                                :hostname => 'test',
                                                :deleteable => true,
                                                :domain_name_servers => ['192.168.42.1'],
                                                :domain_name => 'test.com'), record
  end

  def test_find_record_should_return_lease_by_ip_address
    client_ip = '192.168.42.10'
    lease_expires = Time.now + 120
    @dhcpsapi.expects(:list_subnet_elements).with(@network, anything).returns([{:element => {:reserved_ip_address => '192.168.42.11'}}])
    @dhcpsapi.expects(:get_client_by_ip_address).with(client_ip).returns(
        :client_ip_address => client_ip, :subnet_mask => @netmask, :client_hardware_address => '00:01:02:03:04:05', :client_name => 'test', :client_lease_expires => lease_expires
    )
    @dhcpsapi.expects(:list_subnet_option_values).with(@network).returns(@option_values)

    record = @server.find_record(@network, client_ip)
    assert_equal ::Proxy::DHCP::Lease.new(:subnet => ::Proxy::DHCP::Subnet.new(@network, @netmask),
                                    :ip => client_ip,
                                    :mac => '00:01:02:03:04:05',
                                    :name => 'test',
                                    :ends => lease_expires,
                                    :domain_name_servers => ['192.168.42.1'],
                                    :domain_name => 'test.com'), record
  end

  def test_find_records_by_ip_should_return_reservations_by_ip_address
    client_ip = '192.168.42.10'
    @dhcpsapi.expects(:list_subnet_elements).with(@network, anything).returns([{:element => {:reserved_ip_address => client_ip}}])
    @dhcpsapi.expects(:get_client_by_ip_address).with(client_ip).returns(
        :client_ip_address => client_ip, :subnet_mask => @netmask, :client_hardware_address => '00:01:02:03:04:05', :client_name => 'test', :client_lease_expires => nil
    )
    @dhcpsapi.expects(:list_reserved_option_values).with(client_ip, @network).returns(@option_values)

    record = @server.find_records_by_ip(@network, client_ip)
    assert_equal [::Proxy::DHCP::Reservation.new(:subnet => ::Proxy::DHCP::Subnet.new(@network, @netmask),
                                                :ip => client_ip,
                                                :mac => '00:01:02:03:04:05',
                                                :name => 'test',
                                                :hostname => 'test',
                                                :deleteable => true,
                                                :domain_name_servers => ['192.168.42.1'],
                                                :domain_name => 'test.com')], record
  end

  def test_find_records_by_ip_should_return_leases_by_ip_address
    client_ip = '192.168.42.10'
    lease_expires = Time.now + 120
    @dhcpsapi.expects(:list_subnet_elements).with(@network, anything).returns([{:element => {:reserved_ip_address => '192.168.42.11'}}])
    @dhcpsapi.expects(:get_client_by_ip_address).with(client_ip).returns(
        :client_ip_address => client_ip, :subnet_mask => @netmask, :client_hardware_address => '00:01:02:03:04:05', :client_name => 'test', :client_lease_expires => lease_expires
    )
    @dhcpsapi.expects(:list_subnet_option_values).with(@network).returns(@option_values)

    record = @server.find_records_by_ip(@network, client_ip)
    assert_equal [::Proxy::DHCP::Lease.new(:subnet => ::Proxy::DHCP::Subnet.new(@network, @netmask),
                                    :ip => client_ip,
                                    :mac => '00:01:02:03:04:05',
                                    :name => 'test',
                                    :ends => lease_expires,
                                    :domain_name_servers => ['192.168.42.1'],
                                    :domain_name => 'test.com')], record
  end

  def test_find_record_by_mac_should_return_reservations_by_mac_address
    client_mac = '00:01:02:03:04:05'
    client_ip = '192.168.42.10'
    @dhcpsapi.expects(:list_subnet_elements).with(@network, anything).returns([{:element => {:reserved_ip_address => client_ip}}])
    @dhcpsapi.expects(:get_client_by_mac_address).with('192.168.42.0', client_mac).returns(
        :client_ip_address => client_ip, :subnet_mask => @netmask, :client_hardware_address => client_mac, :client_name => 'test', :client_lease_expires => nil
    )
    @dhcpsapi.expects(:list_reserved_option_values).with(client_ip, @network).returns(@option_values)

    record = @server.find_record_by_mac(@network, client_mac)
    assert_equal ::Proxy::DHCP::Reservation.new(:subnet => ::Proxy::DHCP::Subnet.new(@network, @netmask),
                                                :ip => client_ip,
                                                :mac => client_mac,
                                                :name => 'test',
                                                :hostname => 'test',
                                                :deleteable => true,
                                                :domain_name_servers => ['192.168.42.1'],
                                                :domain_name => 'test.com'), record
  end

  def test_find_records_by_mac_should_return_leases_by_mac_address
    client_mac = '00:01:02:03:04:05'
    client_ip = '192.168.42.10'
    lease_expires = Time.now + 120
    @dhcpsapi.expects(:list_subnet_elements).with(@network, anything).returns([{:element => {:reserved_ip_address => '192.168.42.11'}}])
    @dhcpsapi.expects(:get_client_by_mac_address).with('192.168.42.0', client_mac).returns(
        :client_ip_address => client_ip, :subnet_mask => @netmask, :client_hardware_address => client_mac, :client_name => 'test', :client_lease_expires => lease_expires
    )
    @dhcpsapi.expects(:list_subnet_option_values).with(@network).returns(@option_values)

    record = @server.find_record_by_mac(@network, client_mac)
    assert_equal ::Proxy::DHCP::Lease.new(:subnet => ::Proxy::DHCP::Subnet.new(@network, @netmask),
                                    :ip => client_ip,
                                    :mac => client_mac,
                                    :name => 'test',
                                    :ends => lease_expires,
                                    :domain_name_servers => ['192.168.42.1'],
                                    :domain_name => 'test.com'), record
  end

  def test_should_create_reservation
    client_ip = '192.168.42.10'
    client_mac = '00:01:02:03:04:05'
    client_name = 'test'

    @dhcpsapi.expects(:get_subnet).with(@network).returns(:subnet_address => @network, :subnet_mask => @netmask)
    @server.expects(:create_reservation).with(client_ip, @netmask, client_mac, client_name)
    @server.expects(:build_option_values).with(
        :ip => client_ip, :mac => client_mac, :hostname => client_name, :name => client_name,
        :subnet =>  @network, :option_one => 'option_one_value', :option_two => 'option_two_value').returns(:option_one => 'option_one_value', :option_two => 'option_two_value')
    @server.expects(:set_option_values).with(client_ip, @network, :option_one => 'option_one_value', :option_two => 'option_two_value')

    @server.add_record('ip' => client_ip, 'mac' => client_mac, 'hostname' => client_name, 'network' => @network, :option_one => 'option_one_value', :option_two => 'option_two_value')
  end

  def test_should_raise_exception_when_creating_duplicate_reservation
    client_ip = '192.168.42.10'
    client_mac = '00:01:02:03:04:05'
    client_name = 'test'

    @dhcpsapi.expects(:create_reservation).raises(DhcpsApi::Error.new('', 20_022))
    @dhcpsapi.expects(:get_client_by_ip_address).returns(:client_hardware_address => client_mac, :client_name => client_name, :subnet_mask => @netmask)

    assert_raises(Proxy::DHCP::AlreadyExists) { @server.create_reservation(client_ip, @netmask, client_mac, client_name) }
  end

  def test_should_raise_error_on_attempt_to_create_conflicting_reservation
    client_ip = '192.168.42.10'
    client_mac = '00:01:02:03:04:05'
    client_name = 'test'

    @dhcpsapi.expects(:create_reservation).raises(DhcpsApi::Error.new('', 20_022))
    @dhcpsapi.expects(:get_client_by_ip_address).returns(:client_hardware_address => '00:01:02:03:04:06', :client_name => client_name, :subnet_mask => @netmask)

    assert_raises(Proxy::DHCP::Collision) { @server.create_reservation(client_ip, @netmask, client_mac, client_name) }
  end

  def test_build_option_values_should_skip_not_options
    @dhcpsapi.stubs(:get_option).raises(RuntimeError)
    assert_equal({:hostname => 'test', :option_one => 'one', :option_two => 'two'},
                 @server.build_option_values(:ip => '1.1.1.1',
                                             :mac => '00:01:02:03:04:05',
                                             :hostname => 'test',
                                             :subnet => '1.1.1.0',
                                             :option_one => 'one',
                                             :option_two => 'two'))
  end

  def test_build_option_values_should_clear_pxeclient_opition_if_present
    @dhcpsapi.expects(:get_option).returns('')
    assert_equal({:PXEClient => ''}, @server.build_option_values({}))
  end

  def test_set_option_values
    client_ip = '192.168.42.1'
    @dhcpsapi.expects(:set_reserved_option_value).with(6, client_ip, @network, DhcpsApi::DHCP_OPTION_DATA_TYPE::DhcpIpAddressOption, ['192.168.42.10'])
    @server.set_option_values(client_ip, @network, :domain_name_servers => '192.168.42.10')
  end

  def test_set_option_values_should_skip_unrecognised_options
    assert_nothing_raised { @server.set_option_values('192.168.42.1', @network, :blah => '192.168.42.10') }
  end

  def test_should_delete_reservation
    client_ip = '192.168.42.10'
    client_mac = '00:01:02:03:04:05'
    @dhcpsapi.expects(:delete_reservation).with(client_ip, @network, client_mac)

    @server.del_record(nil, ::Proxy::DHCP::Reservation.new(:ip => client_ip,
                                                           :subnet => ::Proxy::DHCP::Subnet.new(@network, @netmask),
                                                           :mac => client_mac,
                                                           :hostname => 'test'))
  end

  def test_should_delete_lease
    client_ip = '192.168.42.10'
    client_mac = '00:01:02:03:04:05'
    @dhcpsapi.expects(:delete_client_by_ip_address).with(client_ip)

    @server.del_record(nil, ::Proxy::DHCP::Lease.new(:subnet => ::Proxy::DHCP::Subnet.new(@network, @netmask),
                                                     :ip => client_ip,
                                                     :mac => client_mac,
                                                     :hostname => 'test',
                                                     :ends => Time.now))
  end
end
