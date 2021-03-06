require 'cgi'
require 'puppet/node/facts'
require 'puppet/indirector/rest'
require 'puppet/util/puppetdb'
require 'json'
require 'time'

class Puppet::Node::Facts::Puppetdb < Puppet::Indirector::REST
  include Puppet::Util::Puppetdb
  include Puppet::Util::Puppetdb::CommandNames

  def get_trusted_info(node)
    trusted = Puppet.lookup(:trusted_information) do
      Puppet::Context::TrustedInformation.local(node)
    end
    trusted.to_h
  end

  def save(request)
    profile("facts#save", [:puppetdb, :facts, :save, request.key]) do
      current_time = Time.now

      submit_command(request.key, CommandReplaceFacts, 5, current_time.clone.utc) do
        profile("Encode facts command submission payload",
                          [:puppetdb, :facts, :encode]) do
          facts = request.instance.dup
          facts.values = facts.values.dup
          facts.values[:trusted] = get_trusted_info(request.node)

          inventory = facts.values['_puppet_inventory_1']
          package_inventory = inventory['packages'] if inventory.respond_to?(:keys)
          facts.values.delete('_puppet_inventory_1')

          payload_value = {
            "certname" => facts.name,
            "values" => facts.values,
            # PDB-453: we call to_s to avoid a 'stack level too deep' error
            # when we attempt to use ActiveSupport 2.3.16 on RHEL 5 with
            # legacy storeconfigs.
            "environment" => request.options[:environment] || request.environment.to_s,
            "producer_timestamp" => Puppet::Util::Puppetdb.to_wire_time(current_time),
            "producer" => Puppet[:node_name_value]
          }

          if inventory
            payload_value['package_inventory'] = package_inventory
          end

          payload_value
        end
      end
    end
  end

  def find(request)
    profile("facts#find", [:puppetdb, :facts, :find, request.key]) do
      begin
        response = Http.action("/pdb/query/v4/nodes/#{CGI.escape(request.key)}/facts", :query) do |http_instance, uri, ssl_context|
          profile("Query for nodes facts: #{CGI.unescape(uri.path)}",
                  [:puppetdb, :facts, :find, :query_nodes, request.key]) do
            http_instance.get(uri, **{headers: headers,
                                      options: {metric_id: [:puppetdb, :facts, :find],
                                                ssl_context: ssl_context}})
          end
        end
        log_x_deprecation_header(response)

        if response.success?
          profile("Parse fact query response (size: #{response.body.size})",
                  [:puppetdb, :facts, :find, :parse_response, request.key]) do
            result = JSON.parse(response.body)

            facts = result.inject({}) do |a,h|
              a.merge(h['name'] => h['value'])
            end

            Puppet::Node::Facts.new(request.key, facts)
          end
        else
          # Newline characters cause an HTTP error, so strip them
          raise Puppet::Error, "[#{response.code} #{response.reason}] #{response.body.gsub(/[\r\n]/, '')}"
        end
      rescue NotFoundError => e
        # This is what the inventory service expects when there is no data
        return nil
      rescue => e
        raise Puppet::Error, "Failed to find facts from PuppetDB at  #{e}"
      end
    end
  end

  # Search for nodes matching a set of fact constraints. The constraints are
  # specified as a hash of the form:
  #
  # `{type.name.operator => value`
  #
  # The only accepted `type` is 'facts'.
  #
  # `name` must be the fact name to query against.
  #
  # `operator` may be one of {eq, ne, lt, gt, le, ge}, and will default to 'eq'
  # if unspecified.
  def search(request)
    profile("facts#search", [:puppetdb, :facts, :search, request.key]) do
      return [] unless request.options
      operator_map = {
        'eq' => '=',
        'gt' => '>',
        'lt' => '<',
        'ge' => '>=',
        'le' => '<=',
      }
      filters = request.options.sort.map do |key,value|
        type, name, operator = key.to_s.split('.')
        operator ||= 'eq'
        raise Puppet::Error, "Fact search against keys of type '#{type}' is unsupported" unless type == 'facts'
        if operator == 'ne'
          ['not', ['=', ['fact', name], value]]
        else
          [operator_map[operator], ['fact', name], value]
        end
      end

      query = ["and"] + filters
      query_param = CGI.escape(query.to_json)

      begin
        response = Http.action("/pdb/query/v4/nodes?query=#{query_param}", :query) do |http_instance, uri|
          profile("Fact query request: #{CGI.unescape(uri.path)}",
                  [:puppetdb, :facts, :search, :query_request, request.key]) do
            http_instance.get(uri, {headers: headers,
                                    options: { :metric_id => [:puppetdb, :facts, :search] }})
          end
        end
        log_x_deprecation_header(response)

        if response.success?
          profile("Parse fact query response (size: #{response.body.size})",
                  [:puppetdb, :facts, :search, :parse_query_response, request.key,]) do
            JSON.parse(response.body).collect {|s| s["name"]}
          end
        else
          # Newline characters cause an HTTP error, so strip them
          raise Puppet::Error, "[#{response.code} #{response.reason}] #{response.body.gsub(/[\r\n]/, '')}"
        end
      rescue => e
        raise Puppet::Util::Puppetdb::InventorySearchError, e.message
      end
    end
  end

  def headers
    {
      "Accept" => "application/json",
      "Content-Type" => "application/x-www-form-urlencoded; charset=UTF-8",
    }
  end
end
