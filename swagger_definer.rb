require 'uri'

@@paths = {}

class SwaggerDefiner
  attr_accessor :active_path

  def paths
    @@paths
  end

  def parse_response(path, method, code, request, body)
    # Take off any query params before looking at the path
    uri = URI.parse(path)
    path = uri.path

    route = get_route_with_params(path, method)
		# get catched body
		if(@@paths.key?(route[:route]))
			@active_path = @@paths[route[:route]]
		else
			@active_path = SwaggerPathDefinition.new(route[:route])
		end

		# Initialize empty method in a given path
		if(!@active_path.methods.key?(method))
			@active_path.methods[method] = SwaggerMethodDefinition.new(method, route[:tag])
		end

    @active_path.methods[method].add_response_body(code, body)
    
    # We only want to interpret the the request if the response was a success. E.g., if
    # the test was making sure that a 404 is returned if required parameters are left
    # out, then we don't want to log that bad request when generating the documentation.
    if(code == "200" || code == "201")
      @active_path.methods[method].add_request_body(request)

      uri_parameters = uri.query ? Hash[URI.decode_www_form(uri.query)] : {}
      @active_path.methods[method].add_request_query_params(uri_parameters) unless uri_parameters.empty?

      @active_path.methods[method].add_request_path_params(route[:params]) unless route[:params].empty?
    end

    @@paths[route[:route]] = @active_path
  end

  # discover routes, path params, query params, and tags for a given request
  def get_route_with_params(path, method)
    full_hash = Rails.application.routes.recognize_path(path, method: method)
    route_hash = full_hash.except(:action, :controller, :format)
    substituted_path = path
    route_hash.each_pair do |var_name, value|
      substituted_path.sub!(value, "{#{var_name}}")
    end

    extension = '.json'
    if substituted_path.end_with?(extension)
      substituted_path = substituted_path[0..(substituted_path.length - extension.length - 1)]
    end

    suffix = '_controller'
    controller_name = full_hash[:controller]
    tag = controller_name
    if controller_name.end_with?(suffix)
      tag = controller_name[0..(controller_name.length - suffix.length - 1)]
    end

    {
      route: substituted_path,
      params: route_hash,
      tag: tag
    }
  end
end

# used to store swagger endpoint defs
class SwaggerEndpointDefinition
	attr_accessor :paths

	def initialize()
		@paths = {}
	end
end

# stores and parses relevant data for a path
class SwaggerPathDefinition
	attr_accessor :path, :methods

	#request_bodies[code]
	def initialize(path)
		@path = path
		@methods = {}
	end

  def to_hash
    {
      @path => methods.keys.map { |method|
        return methods[method].responses_to_hash
      }.to_h
    }
  end
end

# stores and parses data for and endpoint's method
class SwaggerMethodDefinition
	attr_accessor :method, :request_query_params, :request_path_params, :request_bodies, :response_bodies, :tag

	def initialize(method, tag = '')
		@method = method
    @request_query_params = []
    @request_path_params = []
    @request_bodies = []
		@response_bodies = {}
    @tag = tag
	end

  # adds a body to a method definition 
  def add_response_body(code, body)
    @response_bodies[code] = [] unless @response_bodies[code]
    @response_bodies[code].append(body)
  end

  # adds a request to a method definition
  def add_request_body(request)
    @request_bodies.append(request)
  end

  # once the request has been compacted the requestBody needs to be formatted correctly
  # to do this the required fields are pulled up a level in the hash
  def pull_out_required(body)
    if(body["properties"] != {} && body["properties"].has_key?("required"))
      required = body["properties"]["required"]
      
      body["properties"].delete("required")
      
      required = required.map { |v| v.to_s}
      #request_schema["required"] = required
    end

    body["properties"].each do |key, value|
      if(value["type"] == "object")
        # byebug
        body["properties"][key]["required"] = value["properties"]["required"]
        body["properties"][key]["properties"].delete("required")
      end
    end

    return required
  end

  # add path param to method's request definition
  def add_request_path_params(params)
    @request_path_params.append(params)
  end

  # add query param to method's request definition
  def add_request_query_params(params)
    @request_query_params.append(params)
  end

  # creates the method's swagger schema
  def responses_to_hash
    # generate the request schema using request bodies
    request_schema = get_schema(@request_bodies, true)

    # generates schema for the parameters using path and query parameters in the request
    parameter_schema = get_parameter_schema(@request_path_params, @request_query_params)

    # store tags, parameters, responses
    response_hash = {
      'tags' => [@tag.titleize],
      'parameters' => parameter_schema,
      'responses' => @response_bodies.keys.map { |status_code|
        [status_code.to_s, {
          'description' => "TODO",
          'content' =>
            {
              'application/json' =>
              {
                'schema' => get_schema(@response_bodies[status_code], false)
              }
            }
          }
        ]
      }.to_h
    }

    # create a request body if needed
    if request_schema['properties'] && !request_schema['properties'].empty?
      response_hash['requestBody'] = {
        'content' => {
          'application/json' => {
            'schema' => request_schema
          }
        }
      }
      
      # if required exists format it properly in the request body
      if(request_schema["properties"] != {} && request_schema["properties"].has_key?("required"))
        response_hash['requestBody']['content']['application/json']['schema']['required'] = pull_out_required(request_schema)
      end
    end

    response_hash
  end

  # generate hash for parameters
  def get_parameter_field_hash(path_or_query, name, type, required)
    {
      'in' => path_or_query.to_s,
      'name' => name.to_s,
      'schema' => {
        'type' => type
      },
      'required' => required
    }
  end

  # determine the required state of path and query
  def get_parameter_schema(path_params, query_params)
    path_params_types = {}
    required_path_params = get_request_types_array(path_params.first || {})
    optional_path_params = []
    path_params.each do |request|
      request_types = get_request_types_array(request)
      required_path_params = required_path_params & request_types
      optional_path_params = optional_path_params + (request_types - required_path_params)
    end

    optional_path_params.uniq!

    required_query_params = get_request_types_array(query_params.first || {})
    optional_query_params = []
    query_params.each do |request|
      request_types = get_request_types_array(request)
      required_query_params = required_query_params & request_types
      optional_query_params = optional_query_params + (request_types - required_query_params)
    end

    required_path_params = required_path_params.map { |param|
      get_parameter_field_hash(:path, param[:key_name], param[:type], true)
    }

    optional_path_params = optional_path_params.map { |param|
      get_parameter_field_hash(:path, param[:key_name], param[:type], false)
    }

    required_query_params = required_query_params.map { |param|
      get_parameter_field_hash(:query, param[:key_name], param[:type], true)
    }

    optional_query_params = optional_query_params.map { |param|
      get_parameter_field_hash(:query, param[:key_name], param[:type], false)
    }

    required_path_params + optional_path_params + required_query_params + optional_query_params
  end

  # loop through a set of request or response bodies and compact them.
  # compacting collects all fields in those bodies and combines them into a single hash with no repeates
  # if an array of bodies is found then each element in the array is compacted before the set of compacted bodies are then compacted.
  # during this process if the is_request parameter is set to true then required is extracted from the bodies
  def compact_bodies(bodies, is_request)
    compacted = {}
    containsArrays = bodies[0].is_a? Array
    #byebug
    if(containsArrays)
      temp = []
      bodies.each do |body|
        # recurse and compact the array of bodies
        temp.append(compact_bodies(body, is_request))
      end
      bodies = temp
    end

    bodies = bodies.reject { |b| b.empty? }

    # puts bodies
    if(bodies.length != 0 && is_request)
      compacted["required"] = bodies[0].keys
    end
    bodies.each do |body|
      if(body != {} && body != [])
        if(bodies.length != 0 && is_request)
          compacted["required"] = compacted["required"] - (compacted["required"] - body.keys)
        end
      end
      body.each do |key, value|
        if(!compacted.has_key?(key))
          compacted[key] = value 
        end
        if(value.is_a?(Array) || value.is_a?(Hash))
          if((compacted[key].is_a?(Array) || compacted[key].is_a?(Hash)) &&!compacted[key].any?)
            compacted[key] = value
          end
        end

        if(value.is_a?(Hash) && is_request)
          puts body
          # qbyebug
          if(compacted[key]["required"] == nil)
            compacted[key]["required"] = value.keys.map {|v| v.to_s}
          else
            compacted[key]["required"] = compacted[key]["required"] - (compacted[key]["required"] - value.keys.map { |v| v.to_s})
          end
        end
      end
    end

    if(containsArrays)
      return [compacted]
    end
    return compacted
  end

  # get schema properties parsed as swagger
  def get_schema(body, is_request)
    if(body.is_a? Array)
      if(body.length == 1 && !body[0].is_a?(Array))
        body = body[0]
      else
        body = compact_bodies(body, is_request)
      end
    end

    if(body.is_a?(Array))
      return {
        type: "array",
        items: get_response_types(body)["0"]
      }.stringify_keys
    end
    return {properties: get_response_types(body)}.stringify_keys
  end

  def get_request_types_array(request)
    types_array = []
    request.each_pair do |key, value|
      type_hash = {
        key_name: key,
        type: value.class.name.downcase
      }
      types_array.append(type_hash)
    end
    return types_array
  end

  # legacy code for request schema maybe use later for formdata implementation
  def get_request_schema(requests)
    flattened_requests = requests.map { |request| flatten_hash(request) }
    flattened_requests_types = flattened_requests.map{ |request| get_request_types_array(request)}
    required_keys = flattened_requests_types.first || []
    optional_keys = []

    flattened_requests_types.each do |request|
      # If a key is in required_keys but NOT in this request, then
      # that keys is actually optional, not required. Add it to the
      # optional keys list.
      optional_keys = optional_keys + (required_keys - request)

      # Any keys that are in this request, but not required, must be
      # optional.
      optional_keys = optional_keys + (request - required_keys)

      # And remove anything from the required keys list that isn't
      # in this request.
      required_keys = required_keys & request
    end
    optional_keys.uniq!

    {
      'type' => 'object',
      'properties' => (required_keys + optional_keys).map { |key|
        [key[:key_name].to_s, {'type' => key[:type]}]
      }.to_h,
      'required' => required_keys.map { |required_key| required_key[:key_name].to_s }
    }
  end

  # Code from StockOverflow answer by Uri Agassi
  # https://stackoverflow.com/questions/23521230/flattening-nested-hash-to-a-single-hash-with-ruby-rails#23521624
  def flatten_hash(hash)
    hash.each_with_object({}) do |(k, v), h|
      if v.is_a? Hash
        flatten_hash(v).map do |h_k, h_v|
          h["#{k}[#{h_k}]".to_sym] = h_v
        end
      else
        h[k] = v
      end
    end
  end

  # discover type of parameter value
  def type_check(value)
    if([true, false].include? value)
      return "boolean"
    elsif(value.is_a? Array)
      return "array"
    elsif(value.is_a? Hash)
      return "object"
    elsif(value.is_a? Integer)
      return "integer"
    elsif(value.is_a? Float)
      return "number"
    elsif(value.is_a? String)
      return "string"
    else
      #byebug
      #not possible
    end
  end

  # make sure that the key exists before trying to access/write to it
  def safe_access_hash_value(hash, field)
    if(hash == [])
      return nil
    end
    return hash[field] == nil ? hash[field.to_sym] : hash[field]
  end

  # determine if the field is unique to that array
  def unique_by_field?(arr, field, uniqueVal)
    result = true
    fieldVal = safe_access_hash_value(uniqueVal, field)
    arr.each do |value|
      # the best variable name
      valueFieldVal = safe_access_hash_value(value, field)
      if(fieldVal == valueFieldVal)
        result = false
      end
    end
    return result
  end

  # log all values that show up in an array
  def log_unique(arr)
    unique = []
    arr.each do |v|
      result = unique_by_field?(unique, "type", v)
      # puts result
      # I have no clue why I need to specify true here...but it passes when both true and false otherwise
      if(result == true)
        # byebug
        # "appended: #{v}"
        unique.append(v)
      end
    end
    return unique
  end

  # parses a hash or arrays children recursively to determine types for each
  def get_response_types(response)
    if response.is_a? Array
      temp = {}
      iter = 0
      response.each do |item|
        temp[iter] = item
        iter+=1
      end
      response = temp
    end

    basic_swagger_types = ["number", "integer", "string", "boolean"]
    result = Hash.new# HashWithIndifferentAccess.new
    response.each do |key, value|
      typeData = type_check(value)
      # puts typeData
      if(basic_swagger_types.include? typeData)
        result[key] = { "type" => typeData }
      elsif (typeData === "array")
        if(key == "required" || key == :required)
          result[key] = value
        else
          #byebug
          result[key] = {
            "type": typeData
          }.stringify_keys

          # byebug
          # get_response_types({"0": value[0]}).values[0]
          rJSON = get_response_types(value)
          unique = rJSON.values
          unique = log_unique(unique)
          if(unique.length == 1)
            result[key]["items"] = unique[0].stringify_keys
          elsif(unique.length == 0)
            result[key]["items"] = {"type": "object"}.stringify_keys
          else
            result[key]["items"] = unique.stringify_keys
          end
        end
      elsif (typeData === "object")
        result[key] = {
          'type': typeData,
          'properties': get_response_types(value)
        }.stringify_keys
      elsif (typeData == nil)
        #byebug
      end
    end

    # puts result
    return result.stringify_keys
  end
end

# legacy code may come back to it later ignore for now
class BodyComparer
  attr_accessor :bodies, :required, :shape

  def initialize(bodies)
    bodies.delete({})
    bodies.compact
		@bodies = bodies.compact
    # @required = acquire_required(bodies)
    # @shape = acquire_shape(bodies)
	end
  
  def count_nonoverlapping_keys(body1, body2)
    if Set.new(body1.keys) == Set.new(body2.keys)
      return 0
    end
    
    # we care about longer and shorter so the count doesn't get bloated by keys that don't exist in the shorter
    count = 0
    longer = body1
    shorter = body2
    if(body1.length < body2.length)
      longer = body2
      shorter = body1
    end
    
    shorter.keys.each do keys2
      if(!longer.has_key?(keys2))
        count+=1
      end
    end

    
  end

  def is_matching_body?(body1, body2)
    
  end

  def type_check_array(arr)
    arr.map(&:type_check)
  end

  def is_matching_value?(values1, values2)
    if(values1.length != values2.length)
      return false
    end
    
    values1 = type_check_array(values1)
    values2 = type_check_array(values2)
    
    if(Set.new(values1) == Set.new(values2))
      return true
    end

    return false
  end

  def type_check(value)
    if([true, false].include? value)
      return "boolean"
    elsif(value.is_a? Array)
      type = "none"
      if(value.length > 0)
        type = type_check(value[0])
      end
      return "array #{type}"
    elsif(value.is_a? Hash)
      return "object"
    elsif(value.is_a? Integer)
      return "integer"
    elsif(value.is_a? Float)
      return "number"
    elsif(value.is_a? String)
      return "string"
    else
      #
      #not possible
    end
  end

  def value_type_match?(value1, value2)
    if(type_check(value1) == type_check(value2))
      return true
    end
    return false
  end
end

