module.exports = {
  extends: ['@commitlint/config-angular'],
  plugins: [{
    rules: {
      'angular-body': ({ type, body }) => {
        const length = (body || '').trim().length;
        return [
          (type === 'docs' && length === 0) || length >= 20,
          'include a body of at least 20 characters (optional for docs)',
        ];
      },
    },
  }],
  rules: {
    'type-enum': [2, 'always', [
      'build', 'ci', 'docs', 'feat', 'fix', 'perf', 'refactor', 'revert', 'test',
    ]],
    'body-leading-blank': [2, 'always'],
    'footer-leading-blank': [2, 'always'],
    'angular-body': [2, 'always'],
  },
};
