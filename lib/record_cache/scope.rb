module RecordCache
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
end
