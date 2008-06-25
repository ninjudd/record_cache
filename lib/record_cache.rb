require 'rubygems'
require 'active_record'
require 'memcache_extended'
require 'active_record/dirty'
require File.dirname(__FILE__) + '/cache_version'

module RecordCache
  class Index
    attr_reader :model_class, :index_field, :fields, :scope, :cache, :name
    
    NULL = 'NULL'
    
    def initialize(opts)
      raise ':by => index_field required for cache' if opts[:by].nil?
      raise 'explicit name required with scope'     if opts[:scope] and opts[:name].nil?

      @auto_name    = opts[:name].nil?      
      @write_ahead  = opts[:write_ahead]
      @cache        = opts[:cache] || CACHE
      @model_class  = opts[:class]
      @set_class    = opts[:set_class] || "#{@model_class}Set"
      @index_field  = opts[:by].to_s
      @fields       = opts[:fields].collect {|field| field.to_s}
      @name         = (opts[:name] || "by_#{opts[:by]}").to_s
      @scope        = opts[:scope] || {}
      @scope[:type] = model_class.to_s if sub_class?
    end

    def auto_name?;    @auto_name;    end
    def write_ahead?;  @write_ahead;  end

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
      "#{model_class}_#{CacheVersion.get(model_class)}:#{name}" << ( full_record? ? '' : ":#{fields.join(',')}" )
    end
    
    def find_from_ids(ids, model_class)
      expects_array = ids.first.kind_of?(Array)
      ids = ids.flatten.compact
      ids = stringify(ids)

      if ids.empty?
        return [] if expects_array
        raise ActiveRecord::RecordNotFound, "Couldn't find Profile without an ID"
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
      end
    end
    
    def field_lookup(keys, model_class, field, flag = nil)
      keys = [*keys]
      keys = stringify(keys)
      field = field.to_s if field
      records_by_key = get_records(keys)

      field_by_index = {}
      keys.each do |key|
        records = records_by_key[key]
        fields = field ? records.fields(field, model_class) : records.all_fields(model_class, :except => index_field)
        if flag == :first
          next if fields.empty?
          field_by_index[index_column.type_cast(key)] = fields.first
        else
          field_by_index[index_column.type_cast(key)] = fields
        end
      end
      field_by_index
    end
    
    def invalidate(*keys)
      keys = stringify(keys)
      cache.in_namespace(namespace) do
        keys.each do |key|
          cache.delete(key)
        end
      end
    end

    def invalidate_from_conditions(conditions = nil)
      if conditions
        sql = "SELECT #{index_field} FROM #{table_name} "
        model_class.send(:add_conditions!, sql, conditions, model_class.send(:scope, :find))
        ids = connection.select_values(sql)
        invalidate(*ids)
      else
        CacheVersion.increment(model_class)
      end
    end
    
    def invalidate_model(model)
      if match_previous_scope?(model)
        if write_ahead?
          remove_from_cache(model)
        else
          invalidate( field_was(model, index_field) )
        end
      end
      if match_current_scope?(model)
        if write_ahead?
          add_to_cache(model)
        else
          invalidate( field_is(model, index_field) )
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
    
    def field_was(model, field)
      if [:id, :type, 'id', 'type'].include?(field)
        model.attributes[field]
      else
        model.send("#{field}_was")
      end
    end
    
    def field_is(model, field)
      model.attributes[field.to_s]
    end

    def get_records(keys)
      cache.in_namespace(namespace) do
        cache.get_some(keys) do |keys_to_fetch|
          raise 'db access is disabled' if @@disable_db
          fetched_records = {}
          keys_to_fetch.each do |key|
            fetched_records[key] = RecordCache::Set.new
          end
          sql = "SELECT #{select_fields} FROM #{table_name} WHERE (#{in_clause(keys_to_fetch)})"
          sql << " AND #{scope_conditions}" if not scope_conditions.empty?
          connection.select_all(sql).each do |record|
            key = record[index_field] || NULL
            fetched_records[key] << record
          end
          fetched_records
        end
      end
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
      key    = field_was(model, index_field)
      
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
      record = model.attributes
      key    = record[index_field].to_s
      
      cache.in_namespace(namespace) do
        cache.with_lock(key) do
          if records = cache.get(key)
            records.delete(record)
            records << record
            cache.set(key, records)
          end
        end
      end
    end

    def match_current_scope?(model)
      scope.all? do |field, values|
        [*values].include?( field_is(model, field) )
      end
    end

    def match_previous_scope?(model)
      scope.all? do |field, values|
        [*values].include?( field_was(model, field) )
      end
    end

    def scope_conditions
      @scope_conditions ||= begin
        scope.collect do |attr, value|
          if value.nil?
            "#{attr} IS NULL"
          elsif value.is_a?(Array)
            model_class.send(:sanitize_sql, ["#{attr} IN (?)", value])
          else
            model_class.send(:sanitize_sql, ["#{attr} = ?", value])
          end
        end.join(' AND ')
      end
    end

    def select_fields
      if @select_fields.nil?
        if full_record?
          @select_fields = '*'
        else
          @select_fields = [index_field] + fields
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
      keys.collect {|id| id.nil? ? NULL : id.to_s}.uniq
    end
    
    def connection
      @connection ||= ActiveRecord::Base.respond_to?(:write_connection) ? ActiveRecord::Base.write_connection : ActiveRecord::Base.connection
    end
  end
 
  class Set    
    def initialize(opts = {})
      @records_by_type = {}
    end
        
    def <<(record)
      type = record['type']
      record['id'] = record['id'].to_i if record.has_key?('id')
      
      records_by_type(type) << record
    end
    
    def delete(record)
      raise 'cannot delete record without id' unless record.has_key?('id')
      type = record['type']
      id   = record['id'].to_i

      records_by_type(type).reject! {|r| r['id'] == id}
    end

    def records_by_type(model_class)
      @records_by_type[model_class.to_s] ||= []
    end

    def records(model_class)
      records = if model_class == model_class.base_class
        @records_by_type.values.flatten
      else
        records_by_type(model_class)
      end
      
      records.sort_by {|r| r['id']}
    end

    def size
      @records_by_type.values.inject do |a,b|
        a.size + b.size
      end
    end
    
    def empty?
      @records_by_type.values.all? do |records|
        records.empty?
      end
    end

    def ids(model_class)
      fields('id', model_class)
    end

    def fields(field, model_class)
      records(model_class).collect {|r| model_class.columns_hash[field].type_cast(r[field])}
    end
      
    def all_fields(model_class, opts = {})
      records(model_class).collect do |r|
        record = {}
        r.each do |field, value|
          next if field == opts[:except]
          record[field.to_sym] = model_class.columns_hash[field].type_cast(value)
        end
        record
      end
    end

    def instantiate_first(model_class, full_record)
      if full_record
        record = records(model_class).first
        model_class.send(:instantiate, record) if record
      else
        id = ids(model_class).first
        model_class.find(id) if id
      end
    end

    def instantiate(model_class, full_record)
      if full_record
        records(model_class).collect do |record|
          model_class.send(:instantiate, record)
        end
      else
        model_class.find(ids(model_class))
      end
    end
  end
 
  module InstanceMethods
    def invalidate_record_cache
      self.class.each_cached_index do |index|
        index.invalidate_model(self)
      end
    end
  end
    
  module ClassMethods    
    def find_with_caching(*args, &block)
      if args.last.is_a?(Hash)
        args.last.delete_nils
        args.pop if args.last.empty?
      end
      
      if [:all, :first].include?(args.first)
        if args.last.is_a?(Hash) and args.last.keys == [:conditions] and args.last[:conditions] =~ /^#{table_name}.(\w*) = (\d*)$/
          index = cached_index("by_#{$1}")
          return index.find_by_field([$2], self, args.first) if index
        end
      else
        index = cached_index('by_id')
        return index.find_from_ids(args, self) if index
      end
      find_without_caching(*args, &block)
    end
    
    def update_all_with_invalidate(updates, conditions = nil)
      each_cached_index do |index|
        index.invalidate_from_conditions(conditions)
      end
      update_all_without_invalidate(updates, conditions)
    end

    def delete_all_with_invalidate(conditions = nil)
      each_cached_index do |index|
        index.invalidate_from_conditions(conditions)
      end
      delete_all_without_invalidate(conditions)
    end
    
    def cached_index(name)
      name = name.to_s
      if cached_indexes and cached_indexes[name]
        return cached_indexes[name]
      end
      nil
    end
    
    def each_cached_index
      cached_indexes and cached_indexes.values.each do |index|
        yield(index)
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

      index = RecordCache::Index.new(opts)
      add_cached_index(index)
      first_index = cached_indexes.size == 1

      (class << self; self; end).module_eval do
        if index.includes_id?
          [:first, :all, :set, :ids].each do |type|
            next if type == :ids and index.name == 'by_id'
            define_method( index.find_method_name(type) ) do |keys|
              index.find_by_field(keys, self, type)
            end
          end
        end

        if not index.auto_name? and not index.full_record?
          define_method( "#{index.name.pluralize}_by_#{index.index_field}" ) do |keys|
            index.field_lookup(keys, self, nil)
          end

          define_method( "#{index.name.singularize}_by_#{index.index_field}" ) do |keys|
            index.field_lookup(keys, self, nil, :first)
          end
        end
        
        index.fields.each do |field|
          next if field == index.index_field
          plural_field = field.pluralize
          define_method( "#{plural_field}_by_#{index.index_field}"  ) do |keys|
            index.field_lookup(keys, self, field)
          end
          
          define_method( "#{field}_by_#{index.index_field}"  ) do |keys|
            index.field_lookup(keys, self, field, :first)
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

ActiveRecord::Base.send(:include, ActiveRecord::Dirty)
ActiveRecord::Base.send(:extend,  RecordCache::ActiveRecordExtension)
