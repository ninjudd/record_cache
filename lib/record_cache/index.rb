module RecordCache
  class Index
    attr_reader :model_class, :index_field, :fields, :scope, :order_by, :limit, :cache, :expiry, :name, :prefix
    
    NULL = 'NULL'
    
    def initialize(opts)
      raise ':by => index_field required for cache'    if opts[:by].nil?
      raise 'explicit name or prefix required with scope' if opts[:scope] and opts[:name].nil? and opts[:prefix].nil?

      @auto_name     = opts[:name].nil?      
      @write_ahead   = opts[:write_ahead]
      @cache         = opts[:cache] || CACHE
      @expiry        = opts[:expiry]
      @model_class   = opts[:class]
      @set_class     = opts[:set_class] || "#{@model_class}Set"
      @index_field   = opts[:by].to_s
      @fields        = opts[:fields].collect {|field| field.to_s}
      @prefix        = opts[:prefix]
      @name          = ( opts[:name] || [prefix, 'by', index_field].compact.join('_') ).to_s
      @order_by      = opts[:order_by]
      @limit         = opts[:limit]
      @disallow_null = opts[:null] == false
      
      scope_query = opts[:scope] || {}
      scope_query[:type] = model_class.to_s if sub_class?
      @scope = Scope.new(model_class, scope_query)
    end

    def auto_name?;     @auto_name;     end
    def write_ahead?;   @write_ahead;   end
    def disallow_null?; @disallow_null; end

    def full_record?
      fields.empty?
    end
    
    def includes_id?
      full_record? or fields.include?('id')
    end

    def set_class
      @set_class.constantize
    end

    def namespace
      "#{model_class.name}_#{model_class.version}_#{RecordCache.version}:#{name}" << ( full_record? ? '' : ":#{fields.join(',')}" )
    end
    
    def fields_hash
      if @fields_hash.nil?
        if full_record?
          @fields_hash ||= model_class.column_names.hash
        else
          @fields_hash ||= fields.collect {|field| field.to_s}.hash
        end
      end
      @fields_hash
    end

    def find_by_ids(ids, model_class)
      expects_array = ids.first.kind_of?(Array)
      ids = ids.flatten.compact.collect {|id| id.to_i}
      ids = stringify(ids)

      if ids.empty?
        return [] if expects_array
        raise ActiveRecord::RecordNotFound, "Couldn't find #{model_class} without an ID"
      end
      
      records_by_id = get_records(ids)
   
      models = ids.collect do |id|
        records = records_by_id[id]
        model   = records.instantiate_first(model_class, full_record?) if records

        # try to get record from db again before we throw an exception
        if model.nil?
          invalidate(id)
          records = get_records([id])[id]
          model   = records.instantiate_first(model_class, full_record?) if records
        end

        raise ActiveRecord::RecordNotFound, "Couldn't find #{model_class} with ID #{id}" unless model
        model
      end
      
      if models.size == 1 and not expects_array
        models.first
      else 
        models
      end
    end
    
    def find_by_field(keys, model_class, type)
      keys = [keys] if not keys.kind_of?(Array)
      keys = stringify(keys)
      records_by_key = get_records(keys)

      case type
      when :first
        keys.each do |key|
          model = records_by_key[key].instantiate_first(model_class, full_record?)
          return model if model
        end
        return nil
      when :all
        models = []
        keys.each do |key|
          models.concat( records_by_key[key].instantiate(model_class, full_record?) )
        end
        models
      when :set, :ids
        ids = []
        keys.each do |key|
          ids.concat( records_by_key[key].ids(model_class) )
        end
        type == :set ? set_class.new(ids) : ids
      when :raw
        raw_records = []
        keys.each do |key|
          raw_records.concat( records_by_key[key].records(model_class) )
        end
        raw_records
      end
    end
    
    def field_lookup(keys, model_class, field, flag = nil)
      keys = [*keys]
      keys = stringify(keys)
      field = field.to_s if field
      records_by_key = get_records(keys)

      field_by_index = {}
      all_fields = [].to_ordered_set
      keys.each do |key|
        records = records_by_key[key]
        fields = field ? records.fields(field, model_class) : records.all_fields(model_class, :except => index_field)
        if flag == :all
          all_fields.concat(fields)
        elsif flag == :first
          next if fields.empty?
          field_by_index[index_column.type_cast(key)] = fields.first
        else
          field_by_index[index_column.type_cast(key)] = fields
        end
      end
      if flag == :all
        all_fields.to_a
      else
        field_by_index
      end
    end
    
    def invalidate(*keys)
      keys = stringify(keys)
      cache.in_namespace(namespace) do
        keys.each do |key|
          cache.delete(key)
        end
      end
    end

    def invalidate_from_conditions_lambda(conditions)
      sql = "SELECT #{index_field} FROM #{table_name} "
      model_class.send(:add_conditions!, sql, conditions, model_class.send(:scope, :find))
      ids = db.select_values(sql)
      lambda { invalidate(*ids) }
    end

    def invalidate_from_conditions(conditions)
      invalidate_from_conditions_lambda(conditions).call
    end
    
    def invalidate_model(model)
      attribute     = model.send(index_field)
      attribute_was = model.attr_was(index_field)

      if scope.match_previous?(model)
        if write_ahead?
          remove_from_cache(model)
        else
          invalidate(attribute_was)
        end
      end

      if scope.match_current?(model)
        if write_ahead?
          add_to_cache(model)
        elsif not (scope.match_previous?(model) and attribute_was == attribute)
          invalidate(attribute) 
        end
      end
    end
        
    @@disable_db = false
    def self.disable_db
      @@disable_db = true
    end

    def self.enable_db
      @@disable_db = false
    end
       
    def find_method_name(type)
      if name =~ /(^|_)by_/
        if type == :first
          "find_#{name}"
        else
          "find_#{type}_#{name}"
        end
      else
        case type
        when :all
          "find_#{name}"
        when :first
          "find_#{type}_#{name.singularize}"
        else
          "find_#{name.singularize}_#{type}"
        end
      end
    end
        
  private

    MAX_FETCH = 1000
    def get_records(keys)
      cache.in_namespace(namespace) do
        opts = { 
          :expiry        => expiry,
          :disable_write => model_class.record_cache_config[:disable_write],
          :validation    => lambda {|key, record_set| record_set.fields_hash == fields_hash},
        }
        cache.get_some(keys, opts) do |keys_to_fetch|
          raise 'db access is disabled' if @@disable_db
          fetched_records = {}
          keys_to_fetch.each do |key|
            fetched_records[key] = RecordCache::Set.new(model_class, fields_hash)
          end

          keys_to_fetch.each_slice(MAX_FETCH) do |keys_batch|
            sql = "SELECT #{select_fields} FROM #{table_name} WHERE (#{in_clause(keys_batch)})"
            sql << " AND #{scope.conditions}" if not scope.empty?
            sql << " ORDER BY #{order_by}"    if order_by
            sql << " LIMIT #{limit}"          if limit

            db.select_all(sql).each do |record|
              key = record[index_field] || NULL
              fetched_records[key] << record
            end
          end
          fetched_records
        end
      end
    end

    def model_to_record(model)
      sql = "SELECT #{select_fields} FROM #{table_name} WHERE id = #{model.id}"
      db.select_all(sql).first
    end

    def in_clause(keys)
      conditions = []
      conditions << "#{index_field} IS NULL" if keys.delete(NULL)

      if keys.any?
        values = keys.collect {|value| quote_index_value(value)}.join(',')
        conditions << "#{index_field} IN (#{values})"
      end
      conditions.join(' OR ')
    end

    def remove_from_cache(model)
      record = model.attributes
      key    = model.attr_was(index_field)
      
      cache.in_namespace(namespace) do
        cache.with_lock(key) do
          if records = cache.get(key)
            records.delete(record)
            cache.set(key, records)
          end
        end
      end
    end

    def add_to_cache(model)
      record = model_to_record(model)
      key    = record[index_field].to_s

      cache.in_namespace(namespace) do
        cache.with_lock(key) do
          if records = cache.get(key)
            records.delete(record)
            records << record
            records.sort!(order_by) if order_by
            records.limit!(limit)   if limit
            cache.set(key, records)
          end
        end
      end
    end

    def select_fields
      if @select_fields.nil?
        if full_record?
          @select_fields = '*'
        else
          @select_fields = [index_field, 'id'] + fields
          @select_fields << 'type' if base_class?
          @select_fields = @select_fields.uniq.join(', ')
        end
      end
      @select_fields
    end
    
    def base_class?
      @base_class ||= ( model_class == model_class.base_class and model_class.columns_hash.has_key?('type') )
    end
    
    def sub_class?
      @base_class ||= ( model_class != model_class.base_class )
    end

    def quote_index_value(value)
      model_class.quote_value(value, index_column)
    end
    
    def index_column
      @index_column ||= model_class.columns_hash[index_field]
    end
        
    def table_name
      model_class.table_name
    end
        
    def stringify(keys)
      keys.compact! if disallow_null?
      keys.collect {|key| key.nil? ? NULL : key.to_s}.uniq
    end
    
    def self.db(model_class)
      # Always use the master connection since we are caching.
      db = model_class.connection
      if defined?(DataFabric::ConnectionProxy) and db.kind_of?(DataFabric::ConnectionProxy) and not model_class.record_cache_config[:use_slave]
        db.send(:master)
      else
        db
      end
    end

    def db
      self.class.db(model_class)
    end
  end
end
