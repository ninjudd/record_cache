module RecordCache
  class Set
    attr_reader :model_class, :fields_hash, :time, :hostname

    def self.source_tracking?
      @source_tracking
    end

    def self.source_tracking=(value)
      @source_tracking = value
    end

    def self.hostname
      @hostname ||= Socket.gethostname
    end

    def initialize(model_class, fields_hash = nil)
      raise 'valid model class required' unless model_class

      if self.class.source_tracking?
        @time     = Time.now
        @hostname = self.class.hostname
      end

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
        type.find_by_id(id) if id
      end
    end

    def instantiate(type = model_class, full_record = false)
      if full_record
        records(type).collect do |record|
          type.send(:instantiate, record)
        end
      else
        type.find_all_by_id(ids(type))
      end
    end

  private
    
    def type_cast(field, value)
      column = model_class.columns_hash[field.to_s]
      raise 'column not found in #{model_class} for field #{field}' unless column
      column.type_cast(value)
    end
  end
end
