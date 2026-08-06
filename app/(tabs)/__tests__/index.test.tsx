import React from 'react';
import { render, screen } from '@testing-library/react-native';

import HomeScreen from '../index';

describe('HomeScreen', () => {
  it('renders the MB Converter title', async () => {
    await render(<HomeScreen />);

    expect(screen.getByTestId('home-screen')).toBeOnTheScreen();
    expect(screen.getByTestId('home-title')).toHaveTextContent('MB Converter');
  });
});
