require 'spec_helper'
require 'apol_vcac'

describe Vcac do

  custom_props = {:custom1 => 'value1', :custom2 => 'value2'}

  custom_props_string = '&props=custom1=value1;custom2=value2'

  global_options = {username: ENV['VCAC_USERNAME'],
                    password: ENV['VCAC_PASSWORD'],
                    debug: true}

  it 'should fail with bad hostname for vcac server' do
    args = global_options.merge(url: INVALID_VCAC_URL)

    expect do
      machine_args = {group_id: VALID_GROUP_ID,
                      blueprint_id: VALID_BLUEPRINT_ID}

      m = Vcac::Machine.new(args)
      m.provision(machine_args)

    end.to raise_error

  end

  it 'should fail with a bad group_id' do
    args = global_options.merge(url: VALID_VCAC_URL)

    expect do
      machine_args = {group_id: INVALID_GROUP_ID,
                      blueprint_id: VALID_BLUEPRINT_ID}

      m = Vcac::Machine.new(args)
      m.provision(machine_args)

    end.to raise_error

  end

  it 'should fail with a bad blueprint_id' do
    args = global_options.merge(url: VALID_VCAC_URL)

    expect do
      machine_args = {group_id: VALID_GROUP_ID,
                      blueprint_id: INVALID_BLUEPRINT_ID}

      m = Vcac::Machine.new(args)
      m.provision(machine_args)

    end.to raise_error

  end

  it 'should fail with a bad credentials' do
    args = global_options.merge(url: VALID_VCAC_URL)

    args[:password] = INVALID_PASSWORD

    expect do
      machine_args = {group_id: VALID_GROUP_ID,
                      blueprint_id: VALID_BLUEPRINT_ID}

      m = Vcac::Machine.new(args)
      m.provision(machine_args)

    end.to raise_error

  end

  it 'should provision a machine' do

    args = global_options.merge(url: VALID_VCAC_URL)

    expect do
      machine_args = {group_id: VALID_GROUP_ID,
                      blueprint_id: VALID_BLUEPRINT_ID,
                      custom_props: custom_props,
      }

      m = Vcac::Machine.new(args)
      m.provision(machine_args)

      m.custom_props_string.should eq(custom_props_string)

      puts "Provisioned #{m.last_response['machine_id']}"

    end.not_to raise_error
  end

  it 'should deprovision a machine' do

    args = global_options.merge(url: VALID_VCAC_URL)

    expect do

      machine_args = {machine_name: 'ac-34323'}

      m = Vcac::Machine.new(args)
      m.deprovision(machine_args)

      puts "De-provisioned #{machine_args[:machine_name]}"

    end.not_to raise_error
  end

  it 'should return a machine inventory' do

    expect do

      args = global_options.merge(url: VALID_VCAC_URL)

      m = Vcac::Machine.new(args)
      m.get_vm_inventory

      puts m.normalized_machines_tsv

    end.not_to raise_error
  end

  it 'should return a machines properties' do
    args = global_options.merge(url: VALID_VCAC_URL)

    m = Vcac::Machine.new(args)

    p = m.get_machine_props('dfda121-afa23213-32dfd-dfafa3443-4rrrrr')

    puts p
  end
end
