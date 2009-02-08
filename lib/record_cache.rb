require 'rubygems'
require 'active_record'
require 'ordered_set'
require 'memcache_extended'
require 'cache_version'

module RecordCache
  VERSION = '0.9.1'

  def self.config(opts = nil)
    if opts
      config.merge!(opts)
    else
      @config ||= {}
    end
  end

  class Index
    attr_reader :model_class, :index_field, :fields, :scope, :order_by, :limit, :cache, :expiry, :name
    
    NULL = 'NULL'
    
    def initialize(opts)
      raise ':by => index_field required for cache'    if opts[:by].nil?
      raise 'explicit name required with scope'        if opts[:scope] and opts[:name].nil?

      @auto_name     = opts[:name].nil?      
      @write_ahead   = opts[:write_ahead]
      @cache         = opts[:cache] || CACHE
      @expiry        = opts[:expiry]
      @model_class   = opts[:class]
      @set_class     = opts[:set_class] || "#{@model_class}Set"
      @index_field   = opts[:by].to_s
      @fields        = opts[:fields].collect {|field| field.to_s}
      @name          = (opts[:name] || "by_#{opts[:by]}").to_s
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
      "#{model_class}_#{CacheVersion.get(RecordCache)}_#{CacheVersion.get(model_class)}:#{name}" << ( full_record? ? '' : ":#{fields.join(',')}" )
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
      if name =~ /^by_/
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
 
  class Set    
    attr_reader :model_class, :fields_hash

    def initialize(model_class, fields_hash = nil)
      raise 'valid model class required' unless model_class
      @model_class = model_class
      @fields_hash = fields_hash
      @records_by_type = {}
    end

    def sort!(order_by)
      field, order = order_by.strip.squeeze.split
      descending = (order == 'DESC')
      @records_by_type.values.each do |records|
        sorted_records = records.sort_by do |record|
          type_cast(field, record[field])
        end
        sorted_records.reverse! if descending
        records.replace(sorted_records)
      end
    end
    
    def limit!(limit)
      all_records = records
      if all_records.length > limit
        removed_records = all_records.slice!(limit..-1)
        removed_records.each do |record|
          type = record['type']
          records_by_type(type).delete(record) if type
        end
      end
    end

    def <<(record)
      record_type  = record['type']
      record['id'] = record['id'].to_i if record.has_key?('id')
      
      [record_type, model_class.to_s].uniq.each do |type|
        records_by_type(type) << record
      end
    end
    
    def delete(record)
      raise 'cannot delete record without id' unless record.has_key?('id')
      record_type = record['type']
      id          = record['id'].to_i

      [record_type, model_class.to_s].uniq.each do |type|
        records_by_type(type).reject! {|r| r['id'] == id}
      end
    end

    def records_by_type(type)
      @records_by_type[type.to_s] ||= []
    end

    def records(type = model_class)
      records_by_type(type)
    end

    def size
      records.size
    end
    
    def empty?
      records.empty?
    end

    def ids(type = model_class)
      records(type).collect {|r| r['id']}
    end

    def fields(field, type)
      records(type).collect {|r| type_cast(field, r[field])}
    end
      
    def all_fields(type = model_class, opts = {})
      records(type).collect do |r|
        record = {}
        r.each do |field, value|
          next if field == opts[:except]
          record[field.to_sym] = type_cast(field, value)
        end
        record
      end
    end

    def instantiate_first(type = model_class, full_record = false)
      if full_record
        record = records(type).first
        type.send(:instantiate, record) if record
      else
        id = ids(type).first
        type.find(id) if id
      end
    end

    def instantiate(type = model_class, full_record = false)
      if full_record
        records(type).collect do |record|
          type.send(:instantiate, record)
        end
      else
        type.find(ids(type))
      end
    end

  private
    
    def type_cast(field, value)
      column = model_class.columns_hash[field.to_s]
      raise 'column not found in #{model_class} for field #{field}' unless column
      column.type_cast(value)
    end
  end
 
  class Scope
    attr_reader :model_class, :query
    
    def initialize(model_class, query)
      @model_class = model_class
      @query       = query
    end

    def empty?
      query.empty?
    end

    def fields
      query.keys
    end

    def match_current?(model)
      fields.all? do |field|
        match?( field, model.send(field) )
      end
    end

    def match_previous?(model)
      fields.all? do |field|
        match?( field, model.attr_was(field) )
      end
    end

    def match?(field, value)
      scope = query[field]
      if defined?(AntiObject) and scope.kind_of?(AntiObject)
        scope  = ~scope
        invert = true
      end

      match = [*scope].include?(value)
      invert ? !match : match
    end

    def conditions
      @conditions ||= begin
        query.collect do |field, scope|
          if defined?(AntiObject) and scope.kind_of?(AntiObject)
            scope  = ~scope
            invert = true
          end

          if scope.nil?
            op = invert ? 'IS NOT' : 'IS'
            "#{field} #{op} NULL"
          elsif scope.is_a?(Array)
            op = invert ? 'NOT IN' : 'IN'
            model_class.send(:sanitize_sql, ["#{field} #{op} (?)", scope])
          else
            op = invert ? '!=' : '='
            model_class.send(:sanitize_sql, ["#{field} #{op} ?", scope])
          end
        end.join(' AND ')
      end
      @conditions
    end
  end
 
  module InstanceMethods
    def invalidate_record_cache
      self.class.each_cached_index do |index|
        index.invalidate_model(self)
      end
    end

    def attr_was(attr)
      attr = attr.to_s
      ['id', 'type'].include?(attr) ? send(attr) : send(:attribute_was, attr)
    end
  end
    
  module ClassMethods    
    def find_with_caching(*args, &block)
      if args.last.is_a?(Hash)
        args.last.delete_if {|k,v| v.nil?}
        args.pop if args.last.empty?
      end
      
      if [:all, :first, :last].include?(args.first)
        opts = args.last
        if opts.is_a?(Hash) and opts.keys == [:conditions]
          # Try to match the SQL.
          if opts[:conditions] =~ /^"?#{table_name}"?.(\w*) = (\d*)$/
            field, value = $1, $2
            index = cached_index("by_#{field}")
            return index.find_by_field([value], self, args.first) if index
          end
        end
      elsif not args.last.is_a?(Hash)
        # This is a find with just ids.
        index = cached_index('by_id')
        return index.find_by_ids(args, self) if index
      end

      find_without_caching(*args, &block)
    end
    
    def update_all_with_invalidate(updates, conditions = nil)
      invalidate_from_conditions(conditions, :update) do |conditions|
        update_all_without_invalidate(updates, conditions)
      end
    end

    def delete_all_with_invalidate(conditions = nil)
      invalidate_from_conditions(conditions) do |conditions|
        delete_all_without_invalidate(conditions)
      end
    end
    
    def cached_index(name)
      name = name.to_s
      if cached_indexes and cached_indexes[name]
        return cached_indexes[name]
      end
      nil
    end
    
    def invalidate_from_conditions(conditions, flag = nil)
      if conditions.nil?
        # Just invalidate all indexes.
        result = yield(nil)
        CacheVersion.increment(self)
        return result
      end

      # Freeze ids to avoid race conditions.
      sql = "SELECT id FROM #{table_name} "
      self.send(:add_conditions!, sql, conditions, self.send(:scope, :find))
      ids = RecordCache::Index.db(self).select_values(sql)

      return if ids.empty?
      conditions = "id IN (#{ids.join(',')})"

      if block_given?
        # Capture the ids to invalidate in lambdas.
        lambdas = []
        each_cached_index do |index|
          lambdas << index.invalidate_from_conditions_lambda(conditions)
        end

        result = yield(conditions)

        # Finish invalidating with prior attributes.
        lambdas.each {|l| l.call}      
      end
    
      # Invalidate again afterwards if we are updating (or for the first time if no block was given).
      if flag == :update or not block_given?
        each_cached_index do |index|
          index.invalidate_from_conditions(conditions)
        end
      end

      result
    end
    
    def each_cached_index
      cached_indexes and cached_indexes.values.each do |index|
        yield(index)
      end
    end

    def record_cache_config(opts = nil)
      if opts
        record_cache_config.merge!(opts)
      else
        @record_cache_config ||= RecordCache.config
      end
    end
  end

  module ActiveRecordExtension
    def self.extended(mod)
      mod.send(:class_inheritable_accessor, :cached_indexes)
    end

    def record_cache(*args)
      extend  RecordCache::ClassMethods
      include RecordCache::InstanceMethods

      opts = args.pop
      opts[:fields] = args
      opts[:class]  = self
      field_lookup  = opts.delete(:field_lookup) || []

      index = RecordCache::Index.new(opts)
      add_cached_index(index)
      first_index = cached_indexes.size == 1

      (class << self; self; end).module_eval do
        if index.includes_id?
          [:first, :all, :set, :raw, :ids].each do |type|
            next if type == :ids and index.name == 'by_id'
            define_method( index.find_method_name(type) ) do |keys|
              index.find_by_field(keys, self, type)
            end
          end
        end

        if not index.auto_name? and not index.full_record?
          field = index.fields.first if index.fields.size == 1

          define_method( "all_#{index.name.pluralize}_by_#{index.index_field}" ) do |keys|
            index.field_lookup(keys, self, field, :all)
          end
          
          define_method( "#{index.name.pluralize}_by_#{index.index_field}" ) do |keys|
            index.field_lookup(keys, self, field)
          end

          define_method( "#{index.name.singularize}_by_#{index.index_field}" ) do |keys|
            index.field_lookup(keys, self, field, :first)
          end
        end
        
        if index.auto_name?
          (field_lookup + index.fields).each do |field|
            next if field == index.index_field
            plural_field = field.pluralize

            define_method( "all_#{plural_field}_by_#{index.index_field}"  ) do |keys|
              index.field_lookup(keys, self, field, :all)
            end

            define_method( "#{plural_field}_by_#{index.index_field}"  ) do |keys|
              index.field_lookup(keys, self, field)
            end
            
            define_method( "#{field}_by_#{index.index_field}"  ) do |keys|
              index.field_lookup(keys, self, field, :first)
            end
          end
        end
              
        if first_index
          alias_method_chain :find, :caching
          alias_method_chain :update_all, :invalidate
          alias_method_chain :delete_all, :invalidate
        end
      end
      
      if first_index
        after_save    :invalidate_record_cache
        after_destroy :invalidate_record_cache
      end
    end

    def add_cached_index(index)      
      self.cached_indexes ||= {}
      name  = index.name
      count = nil
      # Make sure the key is unique.
      while cached_indexes["#{name}#{count}"]
        count ||= 0
        count += 1
      end
      cached_indexes["#{name}#{count}"] = index
    end
  
  end
end

ActiveRecord::Base.send(:extend,  RecordCache::ActiveRecordExtension)
