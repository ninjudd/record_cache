class CreateCacheVersions < ActiveRecord::Migration
  def self.up
    CacheVersionMigration.up
  end

  def self.down
    CacheVersionMigration.down
  end
end
