#!/usr/bin/env ruby

require 'spec_helper'
require 'puppet'
require 'puppet/face'
require 'puppet/network/http_pool'

describe "node face: status" do
  let(:subject) { Puppet::Face[:node, :current] }
  let(:headers) do
    {
      "Accept" => "application/json",
      "Content-Type" => "application/x-www-form-urlencoded; charset=UTF-8",
    }
  end

  it "should fail if no node is given" do
    expect { subject.status }.to raise_error ArgumentError, /provide at least one node/
  end

  it "should fetch the status of each node" do
    http = stub 'http'
    Puppet::HTTP::Client.stubs(:new).returns(http)

    nodes = %w[a b c d e]
    nodes.each do |node|
      http.expects(:get).with do |uri, opts|
        headers == opts[:headers] &&
          uri.path == "/pdb/query/v4/nodes/#{node}"
      end
    end

    subject.status(*nodes)
  end

  it "should CGI escape the node names" do
    http = stub 'http'
    Puppet::HTTP::Client.stubs(:new).returns(http)

    node = "foo/+*&bar"

    http.expects(:get).with do |uri, opts|
        headers == opts[:headers] &&
          uri.path == "/pdb/query/v4/nodes/foo%2F%2B%2A%26bar"
    end

    subject.status(node)
  end
end
