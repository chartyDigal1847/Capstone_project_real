<?php

namespace App\Support;

class SearchText
{
    public const FAMILIES = [
        'food' => ['Produce', 'Groceries', 'Staples', 'Bakery', 'Street food', 'Drinks'],
        'tech' => ['Electronics', 'Computers', 'Phones', 'Appliances'],
        'hardware' => ['Hardware', 'Tools', 'Plumbing', 'Electrical'],
        'clothing' => ['Clothing'],
        'household' => ['Household', 'Furniture', 'Appliances'],
    ];

    public const SYNONYMS = [
        'food' => 'food',
        'pagkain' => 'food',
        'grocery' => 'food',
        'groceries' => 'food',
        'produce' => 'food',
        'tech' => 'tech',
        'gadget' => 'tech',
        'electronics' => 'tech',
        'computer' => 'tech',
        'phone' => 'tech',
        'hardware' => 'hardware',
        'tools' => 'hardware',
        'tool' => 'hardware',
        'clothing' => 'clothing',
        'clothes' => 'clothing',
        'household' => 'household',
    ];

    public static function cleaned(string $query): string
    {
        $q = strtolower(trim($query));
        $q = preg_replace('/\b(near me|nearby|around here)\b/', ' ', $q) ?? $q;
        $q = preg_replace('/\s+/', ' ', $q) ?? $q;

        return trim($q);
    }

    public static function matchesCategoryFilter(?string $productCategory, ?string $filter): bool
    {
        $filter = trim((string) $filter);
        if ($filter === '') {
            return true;
        }
        $token = strtolower($filter);
        if (str_starts_with($token, 'family:')) {
            $family = substr($token, 7);
            foreach (self::FAMILIES[$family] ?? [] as $name) {
                if (strcasecmp($name, (string) $productCategory) === 0) {
                    return true;
                }
            }

            return false;
        }

        return strcasecmp((string) $productCategory, $filter) === 0;
    }

    public static function expandedCategories(string $query): array
    {
        $q = self::cleaned($query);
        if ($q === '') {
            return [];
        }
        foreach (preg_split('/\s+/', $q) as $token) {
            $family = self::SYNONYMS[$token] ?? (isset(self::FAMILIES[$token]) ? $token : null);
            if ($family && isset(self::FAMILIES[$family])) {
                return self::FAMILIES[$family];
            }
        }

        return [];
    }

    public static function significantTokens(string $query): array
    {
        $stop = ['for', 'the', 'a', 'an', 'of', 'and', 'or', 'to', 'in', 'on', 'near', 'me', 'nearby', 'with', 'from'];
        $tokens = preg_split('/[^a-z0-9]+/', self::cleaned($query)) ?: [];

        return array_values(array_filter(
            $tokens,
            fn ($token) => strlen($token) >= 2 && ! in_array($token, $stop, true)
        ));
    }

    public static function identifierMatch(string $query, array $fields): bool
    {
        $q = self::cleaned($query);
        if ($q === '') {
            return false;
        }
        $isBarcode = preg_match('/^\d{8,14}$/', $q) === 1;
        $isModel = preg_match('/[a-z]+\d|\d+[a-z]/', $q) === 1;
        foreach ($fields as $field) {
            $value = strtolower((string) $field);
            if ($value === '') {
                continue;
            }
            if ($value === $q) {
                return true;
            }
            if ($isBarcode && preg_replace('/\D+/', '', $value) === $q) {
                return true;
            }
            if ($isModel && str_contains($value, $q)) {
                return true;
            }
        }

        return false;
    }

    public static function semanticScore(string $query, array $fields): float
    {
        $qTokens = self::significantTokens($query);
        if (count($qTokens) < 2) {
            return 0;
        }
        $hay = self::significantTokens(implode(' ', array_map(fn ($field) => (string) $field, $fields)));
        if ($hay === []) {
            return 0;
        }
        $overlap = count(array_intersect($qTokens, $hay));

        return $overlap / max(count($qTokens), 1);
    }

    public static function matches(string $query, array $fields, ?string $category = null): bool
    {
        $q = self::cleaned($query);
        if ($q === '') {
            return true;
        }
        $family = self::expandedCategories($q);
        if ($category && $family) {
            foreach ($family as $name) {
                if (strcasecmp($name, $category) === 0) {
                    return true;
                }
            }
        }
        if (self::identifierMatch($q, $fields) || self::semanticScore($q, $fields) >= 0.4) {
            return true;
        }
        foreach ($fields as $field) {
            $value = strtolower((string) $field);
            if ($value === '') {
                continue;
            }
            if (str_contains($value, $q) || (strlen($value) >= 3 && str_contains($q, $value)) || self::close($value, $q)) {
                return true;
            }
            foreach (preg_split('/[^a-z0-9]+/', $value) as $token) {
                if (strlen($token) < 3) {
                    continue;
                }
                if (str_contains($token, $q) || str_contains($q, $token) || self::close($token, $q)) {
                    return true;
                }
            }
        }

        return false;
    }

    public static function relevance(string $query, string $name, array $aliases = [], ?string $category = null, array $fields = []): int
    {
        $q = self::cleaned($query);
        $name = strtolower($name);
        $allFields = $fields === [] ? [$name, ...$aliases] : $fields;
        if (self::identifierMatch($q, $allFields)) {
            return 0;
        }
        if ($name === $q) {
            return 0;
        }
        if (str_starts_with($name, $q)) {
            return 1;
        }
        if (str_contains($name, $q)) {
            return 2;
        }
        foreach ($aliases as $alias) {
            $alias = strtolower((string) $alias);
            if ($alias === $q || str_contains($alias, $q)) {
                return 3;
            }
        }
        if (self::semanticScore($q, $allFields) >= 0.4) {
            return 4;
        }
        if ($category) {
            foreach (self::expandedCategories($q) as $familyCategory) {
                if (strcasecmp($familyCategory, $category) === 0) {
                    return 5;
                }
            }
        }

        return 8;
    }

    public static function matchKind(string $query, array $fields, ?string $category, int $relevance): string
    {
        if (self::identifierMatch($query, $fields)) {
            return 'identifier';
        }
        if ($relevance <= 3) {
            return 'exact';
        }
        if (self::semanticScore($query, $fields) >= 0.4) {
            return 'semantic';
        }
        if ($category && self::expandedCategories($query) !== []) {
            return 'category';
        }

        return 'exact';
    }

    public static function close(string $a, string $b): bool
    {
        if ($a === '' || $b === '') {
            return false;
        }
        if (abs(strlen($a) - strlen($b)) > 2) {
            return false;
        }

        return levenshtein($a, $b) <= 2;
    }
}
