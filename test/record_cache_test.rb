require File.dirname(__FILE__) + '/test_helper.rb'

CACHE = MemCache.new(
  :ttl=>1800,
  :compression=>false,
  :readonly=>false,
  :debug=>false,
  :c_threshold=>10000,
  :urlencode=>false
)

ActiveRecord::Base.establish_connection(
  :adapter  => "postgresql",
  :host     => "localhost",
  :username => "postgres",
  :password => "",
  :database => "record_cache_test"
)

class CreateTables < ActiveRecord::Migration 
  def self.up
    create_table :pets do |t|
      t.column :breed_id, :bigint
      t.column :name, :string
      t.column :color_id, :bigint
      t.column :sex, :char
      t.column :type, :string
    end

    create_table :breeds do |t|
      t.column :name, :string
    end

    create_table :colors do |t|
      t.column :name, :string
    end
  end

  def self.down
    drop_table :pets
    drop_table :breeds
    drop_table :colors
  end
end

class Pet < ActiveRecord::Base
  belongs_to :breed
  belongs_to :color

  record_cache :by => :id
  record_cache :id, :by => :breed_id
  record_cache :id, :by => :color_id, :write_ahead => true

  record_cache :id, :by => :color_id, :scope => {:sex => 'm'}, :prefix => 'male'
  record_cache :id, :by => :color_id, :scope => {:sex => 'f'}, :prefix => 'female'
  record_cache :id, :by => :color_id, :scope => {:sex => ['m','f']}, :name => 'all_colors'
end

class Dog < Pet
end

class Cat < Pet
end

class Breed < ActiveRecord::Base
end

class Color < ActiveRecord::Base
end

module RecordCache
  class Test < Test::Unit::TestCase
    def setup
      system('memcached -d')
      CACHE.servers = ["localhost:11211"]

      CreateTables.up
      CacheVersionMigration.up
    end
    
    def teardown
      system('killall memcached')
      
      CreateTables.down
      CacheVersionMigration.down
      RecordCache::Index.enable_db
    end
    
    def test_field_lookup
      dog   = Breed.new(:name => 'pitbull retriever')
      cat   = Breed.new(:name => 'house cat')
      willy = Cat.create(:name => 'Willy', :breed => cat)
      daisy = Dog.create(:name => 'Daisy', :breed => dog)

      expected = {dog.id => daisy.id, cat.id => willy.id}
      assert_equal expected, Pet.id_by_breed_id([dog.id, cat.id, 100, 101])      
    end
    
    def test_cache
      color = Color.new(:name => 'black & white')
      dog   = Breed.new(:name => 'pitbull retriever')
      cat   = Breed.new(:name => 'house cat')
      daisy = Dog.create(:name => 'Daisy', :color => color, :breed => dog)
      willy = Cat.create(:name => 'Willy', :color => color, :breed => cat)
      
      Pet.find(daisy.id, willy.id)
      Dog.find_all_by_color_id(color.id)
      Dog.find_all_by_breed_id(dog.id)

      RecordCache::Index.disable_db

      assert_equal Dog,     Dog.find(daisy.id).class
      assert_equal daisy,   Dog.find(daisy.id)
      assert_equal Cat,     Cat.find(willy.id).class
      assert_equal willy,   Cat.find(willy.id)
      assert_equal [daisy], Dog.find_all_by_color_id(color.id)
      assert_equal [willy], Cat.find_all_by_color_id(color.id)
      assert_equal [daisy], Dog.find_all_by_breed_id(dog.id)

      RecordCache::Index.enable_db

      assert_raises(ActiveRecord::RecordNotFound) do
        Dog.find(willy.id)
      end

      assert_raises(ActiveRecord::RecordNotFound) do
        Cat.find(daisy.id)
      end
    end

    def test_find_multiple
      color1 = Color.new(:name => 'black & white')
      color2 = Color.new(:name => 'speckled')
      breed1 = Breed.new(:name => 'pitbull retriever')
      breed2 = Breed.new(:name => 'pitbull terrier')
      daisy = Dog.create(:name => 'Daisy', :color => color1, :breed => breed1)
      sammy = Dog.create(:name => 'Sammy', :color => color1, :breed => breed2)
      
      Dog.find(daisy.id, sammy.id)
      Dog.find_all_by_color_id(color1.id)
      Dog.find_all_by_breed_id([breed1.id, breed2.id])

      RecordCache::Index.disable_db

      assert_equal [daisy, sammy].to_set, Dog.find(daisy.id, sammy.id).to_set
      assert_equal [daisy, sammy].to_set, Dog.find_all_by_color_id(color1.id).to_set
      assert_equal [daisy, sammy].to_set, Dog.find_all_by_breed_id([breed1.id, breed2.id]).to_set
      assert_equal [sammy, daisy].to_set, Dog.find_all_by_breed_id([breed2.id, breed1.id]).to_set
      assert_equal [daisy].to_set,        Dog.find_all_by_breed_id(breed1.id).to_set

      # Alternate find methods.
      #assert_equal [sammy.id, daisy.id], Dog.find_set_by_breed_id([breed2.id, breed1.id]).ids
      assert_equal [sammy.id, daisy.id].to_set, Dog.find_ids_by_breed_id([breed2.id, breed1.id]).to_set

      assert_equal daisy, Dog.find_by_color_id(color1.id)
      assert_equal daisy, Dog.find_by_breed_id([breed1.id, breed2.id])
      assert_equal sammy, Dog.find_by_breed_id([breed2.id, breed1.id])

      baseball = Dog.create(:name => 'Baseball', :color => color2, :breed => breed1)

      RecordCache::Index.enable_db

      assert_equal [daisy, baseball], Dog.find_all_by_breed_id(breed1.id)
    end

    def test_find_raw
      daisy = Dog.create(:name => 'Daisy')
      sammy = Dog.create(:name => 'Sammy')
      
      Dog.find(daisy.id, sammy.id)
      RecordCache::Index.disable_db

      raw_records = Dog.find_raw_by_id([sammy.id, daisy.id])
      assert_equal ['Sammy', 'Daisy'], raw_records.collect {|r| r['name']}
    end

    def test_scope
      color  = Color.new(:name => 'black & white')
      breed1 = Breed.new(:name => 'pitbull retriever')
      breed2 = Breed.new(:name => 'pitbull terrier')
      daisy = Dog.create(:name => 'Daisy', :color => color, :breed => breed1, :sex => 'f')
      sammy = Dog.create(:name => 'Sammy', :color => color, :breed => breed2, :sex => 'm')
      
      assert_equal [sammy],        Dog.find_all_male_by_color_id(color.id)
      assert_equal [daisy],        Dog.find_all_female_by_color_id(color.id)
      assert_equal [daisy, sammy], Dog.find_all_colors(color.id)

      cousin = Dog.create(:name => 'Cousin', :color => color, :breed => breed2, :sex => 'm')

      assert_equal [sammy, cousin],        Dog.find_all_male_by_color_id(color.id)
      assert_equal [daisy, sammy, cousin], Dog.find_all_colors(color.id)
    end

    def test_each_cached_index
      count = 0
      Dog.each_cached_index do |index|
        count += 1
      end
      assert_equal 6, count
    end
    
    def test_save
      b_w   = Color.new(:name => 'black & white')
      brown = Color.new(:name => 'brown')
      breed = Breed.new(:name => 'mutt')
      daisy = Dog.create(:name => 'Daisy', :color => b_w, :breed => breed, :sex => 'f')
      
      assert_equal daisy, Dog.find_by_color_id(b_w.id)
      
      daisy.name  = 'Molly'
      daisy.color = brown
      daisy.save
      
      assert_equal 'Molly', daisy.name
      assert_equal brown.id, daisy.color_id
      
      assert_equal daisy, Dog.find_by_color_id(brown.id)
      assert_equal nil,   Dog.find_by_color_id(b_w.id)
    end

  end
end
