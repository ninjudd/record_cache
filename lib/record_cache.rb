require 'rubygems'
require 'active_record'
require 'geni_memcache'
require 'active_record/dirty'
require File.dirname(__FILE__) + '/cache_version'

module RecordCache
  class Index
    attr_reader :model_class, :field, :scope, :cache, :name
    
    def initialize(opts)
      @model_class  = opts[:model_class]
      @set_class    = opts[:set_class] || "#{opts[:model_class]}Set"
      @field        = opts[:field].to_s
      @scope        = opts[:scope] || {}
      @cache        = opts[:cache]
      @name         = opts[:name]
      @cache_record = opts[:cache_record]
      @use_write_db = opts[:use_write_db]
      @write_ahead  = opts[:write_ahead]
    end

    def cache_record?; @cache_record; end
    def use_write_db?; @use_write_db; end
    def write_ahead?;  @write_ahead;  end

    def set_class
      @set_class.constantize
    end

    def namespace
      "#{model_class}_#{CacheVersion.get(model_class)}:#{name}" << (cache_record? ? '' : ':ids')
    end
    
    def find_from_ids(ids, model_class)
      expects_array = ids.first.kind_of?(Array)
      ids = ids.flatten.compact
      stringify(ids)

      if ids.empty?
        return [] if expects_array
        raise ActiveRecord::RecordNotFound, "Couldn't find Profile without an ID"
      end
      
      records_by_id = get_records(ids)
   
      models = ids.collect do |id|
        record = records_by_id[id]
        model  = record.instantiate_first(model_class) if record
        raise ActiveRecord::RecordNotFound, "Couldn't find #{model_class} with ID #{id}" unless model
        model
      end
      
      if models.size == 1 and not expects_array
        models.first
      else 
        models
      end
    end
    
    def find_by_field(keys, model_class, flag = nil)
      keys = [keys] if not keys.kind_of?(Array)
      stringify(keys)
      records_by_key = get_records(keys)
      
      case flag
      when :first
        keys.each do |key|
          model = records_by_key[key].instantiate_first(model_class)
          return model if model
        end
        return nil
      when :set, :ids
        ids = []
        keys.each do |key|
          ids.concat( records_by_key[key].ids(model_class) )
        end
        flag == :set ? set_class.new(ids) : ids
      else
        models = []
        keys.each do |key|
          models.concat( records_by_key[key].instantiate(model_class) )
        end
        models
      end
    end 
    
    def invalidate(*keys)
      stringify(keys)
      cache.in_namespace(namespace) do
        keys.each do |key|
          cache.delete(key)
        end
      end
    end

    def invalidate_from_conditions(conditions = nil)
      if conditions
        sql = "SELECT #{field_name} FROM #{table_name} "
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
          invalidate( field_was(model, field) )
        end
      end
      if match_current_scope?(model)
        if write_ahead?
          add_to_cache(model)
        else
          invalidate( field_is(model, field) )
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
      cache.get_some(namespace, keys) do |keys_to_fetch|
        raise 'db access is disabled' if @@disable_db
        fetched_records = {}
        keys_to_fetch.each do |key|
          fetched_records[key] = RecordCache::Set.new(:cache_record => cache_record?)
        end
        values = keys_to_fetch.collect {|value| quote_value(value)}.join(',')
        sql = "SELECT #{fields} FROM #{table_name} WHERE #{field_name} IN (#{values})"
        sql << " AND #{scope_conditions}" if not scope_conditions.empty?
        connection.select_all(sql).each do |record|
          key = record[field]
          fetched_records[key] << record
        end
        fetched_records
      end
    end

    def remove_from_cache(model)
      record = model.attributes
      key    = record[field].to_s
      
      cache.in_namespace(namespace) do
        if records = cache.get(key)
          records.delete(record)
          cache.set(key, records)
        end
      end
    end

    def add_to_cache(model)
      record = model.attributes
      key    = record[field].to_s
      
      cache.in_namespace(namespace) do
        if records = cache.get(key)
          records.delete(record)
          records << record
          cache.set(key, records)
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

    def fields
      @fields ||= if cache_record?
        '*'
      else
        @fields = "id, #{field}"
        @fields << ", type" if base_class?
      end
    end
    
    def base_class?
      @base_class ||= begin
        model_class == model_class.base_class and model_class.columns_hash.has_key?('type')
      end
    end

    def quote_value(value)
      @column ||= model_class.columns_hash[field]
      model_class.quote_value(value, @column)
    end
    
    def table_name
      model_class.table_name
    end

    def field_name
      model_class.connection.quote_column_name(field)
    end
        
    def stringify(keys)
      keys.collect! {|id| id.to_s}.uniq!
    end
    
    def connection
      use_write_db? ? model_class.write_connection : model_class.connection
    end
  end
 
  class Set    
    def initialize(opts = {})
      @records_by_type = {}
      @cache_record    = opts[:cache_record]
    end
    
    def cache_record?
      @cache_record
    end
    
    def <<(record)
      type = record['type']
      id   = record['id'].to_i
      
      if cache_record?
        record['id'] = id
        records_by_type(type) << record
      else
        records_by_type(type) << id
      end
    end
    
    def delete(record)
      type = record['type']
      id   = record['id'].to_i

      filter = if cache_record?
        lambda {|r| r['id'] == id}
      else
        lambda {|r| r == id}
      end
      
      records_by_type(type).reject! &filter
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
      
      if cache_record?
        records.sort_by {|r| r['id']}
      else
        records.sort
      end
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
      if cache_record?
        records(model_class).collect {|r| r['id']}
      else
        records(model_class)
      end
    end

    def instantiate_first(model_class)
      if cache_record?
        record = records(model_class).first
        model_class.send(:instantiate, record) if record
      else
        id = records(model_class).first
        model_class.find(id) if id
      end
    end

    def instantiate(model_class)
      if cache_record?
        records(model_class).collect do |record|
          model_class.send(:instantiate, record)
        end
      else
        model_class.find(records(model_class))
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
          index = lookup_cached_index("by_#{$1}")
          return index.find_by_field([$2], self, args.first) if index
        end
        find_without_caching(*args, &block)
      else
        lookup_cached_index('by_id').find_from_ids(args, self)
      end
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
    
    def lookup_cached_index(name)
      [class_name, base_class.to_s].uniq.each do |model_class|
        if cached_indexes[model_class] and cached_indexes[model_class][name]
          return cached_indexes[model_class][name]
        end
      end
      nil
    end
    
    def each_cached_index
      [class_name, base_class.to_s].uniq.each do |model_class|
        if cached_indexes[model_class]
          cached_indexes[model_class].values.each do |index|
            yield(index)
          end
        end
      end
    end
  end

  module ActiveRecordExtension
    def cache_by(field, opts = {})
      extend  RecordCache::ClassMethods
      include RecordCache::InstanceMethods

      opts[:field]       = field.to_s
      opts[:model_class] = self
      opts[:cache] ||= CACHE
      opts[:cache_record] ||= opts[:field] == 'id'
      
      raise 'explicit name required with scope' if opts[:scope] and not opts[:name]
      opts[:name]  ||= "by_#{opts[:field]}"
      opts[:scope] ||= {}
      opts[:scope][:type] = self.to_s if self != base_class

      index = RecordCache::Index.new(opts)
      index_count = add_cached_index(opts[:name], index)

      (class << self; self; end).module_eval do
        define_method( index.find_method_name(:first) ) do |keys|
          index.find_by_field(keys, self, :first)
        end
      
        define_method( index.find_method_name(:all) ) do |keys|
          index.find_by_field(keys, self)
        end

        define_method( index.find_method_name(:set) ) do |keys|
          index.find_by_field(keys, self, :set)
        end

        define_method( index.find_method_name(:ids) ) do |keys|
          index.find_by_field(keys, self, :ids)
        end
      
        alias_method_chain :find, :caching if opts[:field] == 'id'
      
        if index_count == 1
          alias_method_chain :update_all, :invalidate
          alias_method_chain :delete_all, :invalidate
        end
      end

      if index_count == 1
        after_save    :invalidate_record_cache
        after_destroy :invalidate_record_cache
      end
    end
    
    @@cached_indexes = {}
    def cached_indexes
      @@cached_indexes
    end

    def add_cached_index(name, index)
      cached_indexes[class_name] ||= {}
      cached_indexes[class_name][name] = index
      cached_indexes[class_name].size
    end
  
  end
end

ActiveRecord::Base.send(:include, ActiveRecord::Dirty)
ActiveRecord::Base.send(:extend,  RecordCache::ActiveRecordExtension)