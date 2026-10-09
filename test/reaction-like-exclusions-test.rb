# frozen_string_literal: true
# Reuse the isolated database guard and real post/API fixtures.
require_relative "reaction-deny-list-test"

class ReactionDenyListTest
  def test_excluded_like_codes_cover_aliases_colons_and_all_skin_tones
    %w[-1 thumbsdown :thumbsdown: -1:t2 thumbsdown:t6 :thumbsdown:t3:].each do |code|
      assert_includes R::Reaction.reactions_excluded_from_like, code
    end
    refute_includes R::Reaction.reactions_excluded_from_like, "+1:t3"
    refute_includes R::Reaction.reactions_excluded_from_like, "laughing"
  end

  def test_excluded_variants_never_create_shadow_likes
    %w[-1 thumbsdown :thumbsdown: -1:t2 thumbsdown:t6 :thumbsdown:t3:].each do |code|
      who = user("variant")
      toggle(code, who)
      assert R::ReactionUser.exists?(post: @post, user: who), code
      refute PostAction.exists?(post: @post, user: who, post_action_type_id: PostActionType::LIKE_POST_ACTION_ID), code
    end
    assert_equal 0, @post.reload.like_count
    assert_equal 6, H.reaction_users_count_for_post(Post.find(@post.id), @guardian)
    toggle("+1:t3", @other)
    assert PostAction.exists?(post: @post, user: @other, post_action_type_id: PostActionType::LIKE_POST_ACTION_ID)
  end

  def test_switching_between_positive_and_negative_variants_updates_likes
    toggle("laughing")
    assert_equal 1, @post.reload.like_count
    toggle("thumbsdown:t3")
    assert_equal 0, @post.reload.like_count
    toggle("clap")
    assert_equal 1, @post.reload.like_count
    assert_equal "clap", R::ReactionUser.find_by(post: @post, user: @user).reaction.reaction_value
  end

  def test_exclusion_setting_cache_and_alias_configuration
    SiteSetting.discourse_reactions_excluded_from_like = ""
    assert_empty R::Reaction.reactions_excluded_from_like
    SiteSetting.discourse_reactions_enabled_reactions = "laughing|thumbsdown|-1:t2"
    SiteSetting.discourse_reactions_excluded_from_like = "thumbsdown"
    assert_includes R::Reaction.reactions_excluded_from_like, "-1:t3"
    SiteSetting.discourse_reactions_excluded_from_like = "-1:t2"
    assert_includes R::Reaction.reactions_excluded_from_like, "thumbsdown:t2"
    refute_includes R::Reaction.reactions_excluded_from_like, "-1:t3"
    refute_includes R::Reaction.reactions_excluded_from_like, "-1"
  end

  def test_official_synchronizer_repairs_historical_variant_likes_without_deleting_reactions
    # Simulate the old exact-match policy, using the actual write path.
    original = R::Reaction.method(:reactions_excluded_from_like)
    begin
      R::Reaction.define_singleton_method(:reactions_excluded_from_like) { ["-1"] }
      toggle("thumbsdown:t3")
    ensure
      R::Reaction.define_singleton_method(:reactions_excluded_from_like, original)
    end
    assert_equal 1, @post.reload.like_count
    SiteSetting.discourse_reactions_like_sync_enabled = true
    R::ReactionLikeSynchronizer.sync!
    assert_equal 0, @post.reload.like_count
    assert_equal 0, @post.topic.reload.like_count
    assert R::ReactionUser.exists?(post: @post, user: @user)
    refute PostAction.exists?(post: @post, user: @user, post_action_type_id: PostActionType::LIKE_POST_ACTION_ID)
    assert_equal ["thumbsdown:t3"], H.reactions_for_post(Post.find(@post.id), @guardian).map { |r| r[:id] }
  end
end
