-- name: CreateProfile :one
INSERT INTO profiles (
    id, user_id, parent_profile_id, name,
    system_message, default_user_message, compression_guide,
    compression_mode, compression_provider_id, compression_model_id,
    default_settings,
    title_provider_id, title_model_id, title_guide
) VALUES (
    $1, $2, $3, $4,
    $5, $6, $7,
    $8, $9, $10,
    $11,
    $12, $13, $14
)
RETURNING *;

-- name: GetProfileByID :one
SELECT * FROM profiles WHERE id = $1;

-- name: ListProfilesByUser :many
SELECT * FROM profiles WHERE user_id = $1 ORDER BY created_at;

-- name: DeleteProfile :exec
DELETE FROM profiles WHERE id = $1;

-- name: UpdateProfileName :exec
UPDATE profiles SET name = $2, updated_at = NOW() WHERE id = $1;

-- name: UpdateProfileSystemMessage :exec
UPDATE profiles SET system_message = $2, updated_at = NOW() WHERE id = $1;

-- name: UpdateProfileDefaultUserMessage :exec
UPDATE profiles SET default_user_message = $2, updated_at = NOW() WHERE id = $1;

-- name: UpdateProfileCompressionGuide :exec
UPDATE profiles SET compression_guide = $2, updated_at = NOW() WHERE id = $1;

-- name: UpdateProfileCompressionMode :exec
UPDATE profiles SET compression_mode = $2, updated_at = NOW() WHERE id = $1;

-- name: UpdateProfileCompressionProviderID :exec
UPDATE profiles SET compression_provider_id = $2, updated_at = NOW() WHERE id = $1;

-- name: UpdateProfileCompressionModelID :exec
UPDATE profiles SET compression_model_id = $2, updated_at = NOW() WHERE id = $1;

-- name: UpdateProfileDefaultSettings :exec
UPDATE profiles SET default_settings = $2, updated_at = NOW() WHERE id = $1;

-- name: UpdateProfileTitleProviderID :exec
UPDATE profiles SET title_provider_id = $2, updated_at = NOW() WHERE id = $1;

-- name: UpdateProfileTitleModelID :exec
UPDATE profiles SET title_model_id = $2, updated_at = NOW() WHERE id = $1;

-- name: UpdateProfileTitleGuide :exec
UPDATE profiles SET title_guide = $2, updated_at = NOW() WHERE id = $1;
