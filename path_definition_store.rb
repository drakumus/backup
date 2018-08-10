module PathDefinitionStore

  @definitions = nil

  class << self

    def update_path_definitions(swagger_definer)
      @definitions = swagger_definer
    end

    def get_definitions
      @definitions
    end

    def get_swagger_document
      # @definitions is a SwaggerDefiner object. SwaggerDefiner.paths
      # gives you a hash, with the keys being a URL and the values being
      # SwaggerPathDefinition objects. SwaggerPathDefinition.methods is a hash,
      # with the keys being :get, :post, etc, and the values being
      # SwaggerMethodDefinition objects. Those have the responses_to_hash method
      # on them.
      {
        'openapi' => '3.0.0',
        'info' => {'version' => "v1", 'title' => "Canvas LMS"},
        'paths' => get_definitions.paths.keys.map { |path_url|
          [path_url, get_definitions.paths[path_url].methods.keys.map { |http_method|
             [http_method.to_s, get_definitions.paths[path_url].methods[http_method].responses_to_hash]
           }.to_h
          ]
        }.to_h
      }.to_yaml
    end
  end
end

