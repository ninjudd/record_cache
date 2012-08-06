require 'rubygems'
require 'memcache'
require 'active_record'
require 'ordered_set'
require 'cache_version'
require 'deferrable'

$:.unshift(File.dirname(__FILE__))
require 'record_cache/index'
require 'record_cache/set'
require 'record_cache/scope'

module RecordCache
  def self.config(opts = nil)
    if opts
      config.merge!(opts)
    else
      @config ||= {}
    end
  end
  def self.with_config(opts)
    old, @config = @config, @config.merge(opts)
    yield
  ensure
    @config = old
  end
 
 
  def self.db(model_class)
    # Always use the master connection since we are caching.
    db = model_class.connection
    if false && defined?(DataFabric::ConnectionProxy) and db.kind_of?(DataFabric::ConnectionProxy)
      model_class.record_cache_config[:use_slave] ? db.send(:connection) : db.send(:master)
    else
      db
    end
  end

  module InstanceMethods
    def invalidate_record_cache
      self.class.each_cached_index do |index|
        index.invalidate_model(self) 
        index.clear_deferred
      end
    end

    def invalidate_record_cache_deferred
      self.class.each_cached_index do |index|
        # Have to invalidate both before and after commit.
        index.invalidate_model(self)
      end
    end

    def complete_deferred_record_cache_invalidations
      self.class.each_cached_index do |index|
        index.complete_deferred
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
          if opts[:conditions] =~ /^"?#{table_name}"?."?(\w+)"? = (?:(\d+)|'(\w+)')$/
            field = $1
            value = ($3 || $2)
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

    # Match sql with regex, locate the index and query cache/db
    def match_and_find_by_field(sql, regex, type)
      match_data = regex.match(sql)
      if match_data
          field = match_data[1]
          value = (match_data[3] || match_data[2])
          index = cached_index("by_#{field}")
          if index
            records = index.find_by_field([value], self, type)
            # we must return an array
            if records.is_a?(Array)
              return records
            end
            return records ? [records]  : []
          end
      end
    end
    private :match_and_find_by_field

    # ActiveRecord ends up making a call to find_by_sql in the case of associations
    # for example in a call to Company.first.employees
    def find_by_sql_with_caching(*args, &block)
      if args.is_a?(Array) and args.size==1
        regex_nolimit   = /^SELECT\s+\S+\.\*\s+FROM\s+\S+\s+WHERE\s+\("?#{table_name}"?."?(\w+)"?\s+=\s+(?:(\d+)|'(\w+)')\)$/
        regex_withlimit = /^SELECT\s+\S+\.\*\s+FROM\s+\S+\s+WHERE\s+\("?#{table_name}"?."?(\w+)"?\s+=\s+(?:(\d+)|'(\w+)')\)\s+LIMIT\s+1$/
        if records = match_and_find_by_field(args.first, regex_nolimit, :all)
          return records
        elsif records = match_and_find_by_field(args.first, regex_withlimit, :first)
          return records
        end
      end

      # All other queries are sent back to ActiveRecord
      find_by_sql_without_caching(*args, &block)
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

    def delete_with_invalidate(id)
      raise "Unexpected type for RecordCache delete_with_invalidate id=#{id.inspect}" unless id.is_a? Fixnum
      invalidate_from_conditions(:id => id) do |conditions|
        delete_without_invalidate(id)
      end
    end

    def invalidate_from_conditions(conditions, flag = nil)
      if conditions.nil?
        # Just invalidate all indexes.
        result = yield(nil)
        self.increment_version
        return result
      end

      # Freeze ids to avoid race conditions.
      sql = self.select(:id).where(conditions).to_sql
      ids = RecordCache.db(self).select_values(sql)

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

    def cached_indexes
      @cached_indexes ||= {}
    end

    def cached_index(name)
      name = name.to_s
      index = cached_indexes[name]
      index ||= base_class.cached_index(name) if base_class != self and base_class.respond_to?(:cached_index)
      index
    end

    def add_cached_index(index)
      name  = index.name
      count = nil
      # Make sure the key is unique.
      while cached_indexes["#{name}#{count}"]
        count ||= 0
        count += 1
      end
      cached_indexes["#{name}#{count}"] = index
    end

    def each_cached_index
      cached_index_names.each do |index_name|
        yield cached_index(index_name)
      end      
    end

    def cached_index_names
      names = cached_indexes.keys
      names.concat(base_class.cached_index_names) if base_class != self and base_class.respond_to?(:cached_index_names)
      names.uniq
    end

    def record_cache_config(opts = nil)
      @record_cache_config ||= {}
      @record_cache_config.merge!(opts) if opts
      RecordCache.config.merge(@record_cache_config)
    end
    
    def with_record_cache_config(opts)
       old, @record_cache_config = @record_cache_config, @record_cache_config.merge(opts)
       yield
    ensure
       @record_cache_config = old
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
      first_index = (cached_indexes.size == 1)

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
            prefix = index.prefix
            prefix = "#{prefix}_" if prefix

            define_method( "all_#{prefix}#{plural_field}_by_#{index.index_field}"  ) do |keys|
              index.field_lookup(keys, self, field, :all)
            end

            define_method( "#{prefix}#{plural_field}_by_#{index.index_field}"  ) do |keys|
              index.field_lookup(keys, self, field)
            end
            
            define_method( "#{prefix}#{field}_by_#{index.index_field}"  ) do |keys|
              index.field_lookup(keys, self, field, :first)
            end
          end
        end
              
        if first_index
          alias_method_chain :find,         :caching
          alias_method_chain :find_by_sql,  :caching
          alias_method_chain :update_all,   :invalidate
          alias_method_chain :delete_all,   :invalidate
          alias_method_chain :delete,       :invalidate
        end
      end
      
      if first_index
        after_save     :invalidate_record_cache_deferred
        after_destroy  :invalidate_record_cache_deferred
        after_commit   :complete_deferred_record_cache_invalidations
        after_rollback :complete_deferred_record_cache_invalidations
      end
    end
  end
end

ActiveRecord::Base.send(:extend,  RecordCache::ActiveRecordExtension)
